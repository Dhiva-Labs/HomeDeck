package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

// probePorts mirrors the app's sweep: enough to prove a host is alive and to
// guess what it is.
var probePorts = []int{22, 80, 443, 445, 554, 631, 1883, 5000, 8080, 8123, 9100}

// Host is one device seen on the LAN.
type Host struct {
	IP       string    `json:"ip"`
	MAC      string    `json:"mac,omitempty"`
	Name     string    `json:"name,omitempty"`
	Kind     string    `json:"kind"`
	Ports    []int     `json:"ports"`
	Online   bool      `json:"online"`
	LastSeen time.Time `json:"lastSeen"`
}

// Scanner keeps a continuously refreshed view of the LAN. Unlike the app it
// runs 24/7, so presence history survives the panel's screen being off.
type Scanner struct {
	mu      sync.RWMutex
	hosts   map[string]*Host
	subnet  string
	localIP string
}

func NewScanner() (*Scanner, error) {
	ip, subnet, err := localSubnet()
	if err != nil {
		return nil, err
	}
	return &Scanner{
		hosts:   make(map[string]*Host),
		subnet:  subnet,
		localIP: ip,
	}, nil
}

// Hosts returns a snapshot safe to serialize while a scan is running.
func (s *Scanner) Hosts() []*Host {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*Host, 0, len(s.hosts))
	for _, h := range s.hosts {
		copied := *h
		out = append(out, &copied)
	}
	return out
}

// Run scans immediately, then on every tick until ctx-less shutdown.
func (s *Scanner) Run(interval time.Duration) {
	s.Scan()
	for range time.Tick(interval) {
		s.Scan()
	}
}

// Scan sweeps the subnet and folds the results into the host table.
func (s *Scanner) Scan() {
	found := make(map[string]*Host)
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 128)

	for i := 1; i <= 254; i++ {
		ip := fmt.Sprintf("%s.%d", s.subnet, i)
		wg.Add(1)
		go func(ip string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			open := probeHost(ip)
			if open == nil {
				return
			}
			mu.Lock()
			found[ip] = &Host{
				IP:       ip,
				Ports:    open,
				Online:   true,
				LastSeen: time.Now(),
			}
			mu.Unlock()
		}(ip)
	}
	wg.Wait()

	arp := readARP()
	for ip, h := range found {
		h.MAC = arp[ip]
		h.Kind = guessKind(h.Ports)
		if names, err := net.LookupAddr(ip); err == nil && len(names) > 0 {
			h.Name = strings.TrimSuffix(strings.Split(names[0], ".")[0], ".")
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	// Anything previously known but absent this round is offline, not gone —
	// a phone that went to sleep should still be listed.
	for ip, h := range s.hosts {
		if _, ok := found[ip]; !ok {
			h.Online = false
		}
	}
	for ip, h := range found {
		if existing, ok := s.hosts[ip]; ok {
			existing.Online = true
			existing.Ports = h.Ports
			existing.LastSeen = h.LastSeen
			if h.MAC != "" {
				existing.MAC = h.MAC
			}
			if h.Name != "" {
				existing.Name = h.Name
			}
			existing.Kind = h.Kind
		} else {
			s.hosts[ip] = h
		}
	}
}

// probeHost returns the open ports, or nil when nothing answered. A refused
// connection still proves the host exists, so it yields an empty non-nil slice.
func probeHost(ip string) []int {
	open := []int{}
	alive := false
	for _, port := range probePorts {
		addr := net.JoinHostPort(ip, fmt.Sprint(port))
		conn, err := net.DialTimeout("tcp", addr, 400*time.Millisecond)
		if err == nil {
			conn.Close()
			open = append(open, port)
			alive = true
			continue
		}
		if strings.Contains(err.Error(), "refused") {
			alive = true
		}
	}
	if !alive {
		return nil
	}
	return open
}

func guessKind(ports []int) string {
	has := func(p int) bool {
		for _, v := range ports {
			if v == p {
				return true
			}
		}
		return false
	}
	switch {
	case has(9100) || has(631):
		return "printer"
	case has(554):
		return "camera"
	case has(5000) && has(445):
		return "nas"
	case has(8123):
		return "homeassistant"
	case has(1883):
		return "mqtt"
	case has(22) || has(445):
		return "computer"
	default:
		return "unknown"
	}
}

func localSubnet() (string, string, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "", "", err
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok || ipnet.IP.To4() == nil {
				continue
			}
			ip := ipnet.IP.To4().String()
			if strings.HasPrefix(ip, "169.254.") {
				continue
			}
			idx := strings.LastIndex(ip, ".")
			return ip, ip[:idx], nil
		}
	}
	return "", "", fmt.Errorf("no usable IPv4 interface")
}

// readARP maps IP to MAC from the kernel ARP table.
func readARP() map[string]string {
	result := make(map[string]string)
	file, err := os.Open("/proc/net/arp")
	if err != nil {
		return result
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Scan() // header
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 {
			continue
		}
		mac := strings.ToLower(fields[3])
		if mac == "00:00:00:00:00:00" || !strings.Contains(mac, ":") {
			continue
		}
		result[fields[0]] = mac
	}
	return result
}

// WakeOnLAN sends a magic packet to the subnet broadcast.
func WakeOnLAN(mac string) error {
	cleaned := strings.NewReplacer(":", "", "-", "").Replace(mac)
	hw, err := hex.DecodeString(cleaned)
	if err != nil || len(hw) != 6 {
		return fmt.Errorf("invalid MAC address %q", mac)
	}

	packet := make([]byte, 0, 102)
	for i := 0; i < 6; i++ {
		packet = append(packet, 0xFF)
	}
	for i := 0; i < 16; i++ {
		packet = append(packet, hw...)
	}

	conn, err := net.Dial("udp", "255.255.255.255:9")
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = conn.Write(packet)
	return err
}
