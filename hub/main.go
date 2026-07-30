// HomeDeck Hub — a single binary that gives old devices a way in.
//
// It scans the LAN continuously (which a sleeping phone cannot), sends
// Wake-on-LAN packets, transcodes RTSP cameras to MJPEG that any browser can
// show, and serves a dashboard plain enough for a 2012 phone or an iOS 6 iPad.
package main

import (
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

type Config struct {
	Cameras []CameraConfig `json:"cameras"`
}

type Hub struct {
	scanner    *Scanner
	restreamer *Restreamer

	mu      sync.RWMutex
	config  Config
	cfgPath string
}

func main() {
	addr := flag.String("addr", ":8477", "listen address")
	cfgPath := flag.String("config", "homedeck-hub.json", "camera config file")
	interval := flag.Duration("scan-interval", 2*time.Minute, "network scan interval")
	fps := flag.Int("fps", 5, "restream frame rate")
	width := flag.Int("width", 640, "restream width in pixels")
	quality := flag.Int("quality", 7, "JPEG quality, 2 (best) to 31 (worst)")
	flag.Parse()

	scanner, err := NewScanner()
	if err != nil {
		log.Fatalf("hub: %v", err)
	}

	hub := &Hub{
		scanner:    scanner,
		restreamer: NewRestreamer(*fps, *width, *quality),
		cfgPath:    *cfgPath,
	}
	if err := hub.loadConfig(); err != nil {
		log.Printf("hub: no camera config loaded (%v); add cameras via the API", err)
	}

	go scanner.Run(*interval)

	mux := http.NewServeMux()
	hub.routes(mux)

	log.Printf("HomeDeck Hub listening on %s (scanning %s.0/24)", *addr, scanner.subnet)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

func (h *Hub) routes(mux *http.ServeMux) {
	mux.HandleFunc("/api/hosts", h.handleHosts)
	mux.HandleFunc("/api/cameras", h.handleCameras)
	mux.HandleFunc("/api/wake", h.handleWake)
	mux.HandleFunc("/api/scan", h.handleScan)
	mux.HandleFunc("/stream/", h.handleStream)
	mux.HandleFunc("/snapshot/", h.handleSnapshot)
	mux.HandleFunc("/", h.handleDashboard)
}

func (h *Hub) cameras() []CameraConfig {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return append([]CameraConfig(nil), h.config.Cameras...)
}

func (h *Hub) cameraByID(id string) (CameraConfig, bool) {
	for _, cam := range h.cameras() {
		if cam.ID == id {
			return cam, true
		}
	}
	return CameraConfig{}, false
}

func (h *Hub) loadConfig() error {
	data, err := os.ReadFile(h.cfgPath)
	if err != nil {
		return err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return err
	}
	h.mu.Lock()
	h.config = cfg
	h.mu.Unlock()
	return nil
}

func (h *Hub) saveConfig() error {
	h.mu.RLock()
	data, err := json.MarshalIndent(h.config, "", "  ")
	h.mu.RUnlock()
	if err != nil {
		return err
	}
	return os.WriteFile(h.cfgPath, data, 0o644)
}

// ---- handlers --------------------------------------------------------------

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func (h *Hub) handleHosts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, h.scanner.Hosts())
}

func (h *Hub) handleScan(w http.ResponseWriter, r *http.Request) {
	go h.scanner.Scan()
	writeJSON(w, map[string]string{"status": "scanning"})
}

func (h *Hub) handleCameras(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, h.cameras())
	case http.MethodPost:
		var cam CameraConfig
		if err := json.NewDecoder(r.Body).Decode(&cam); err != nil {
			http.Error(w, "bad camera payload", http.StatusBadRequest)
			return
		}
		if cam.ID == "" || cam.StreamURL == "" {
			http.Error(w, "id and streamUrl are required", http.StatusBadRequest)
			return
		}
		h.mu.Lock()
		replaced := false
		for i, existing := range h.config.Cameras {
			if existing.ID == cam.ID {
				h.config.Cameras[i] = cam
				replaced = true
				break
			}
		}
		if !replaced {
			h.config.Cameras = append(h.config.Cameras, cam)
		}
		h.mu.Unlock()
		if err := h.saveConfig(); err != nil {
			log.Printf("hub: could not save config: %v", err)
		}
		writeJSON(w, cam)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (h *Hub) handleWake(w http.ResponseWriter, r *http.Request) {
	mac := r.URL.Query().Get("mac")
	if mac == "" {
		http.Error(w, "mac parameter required", http.StatusBadRequest)
		return
	}
	if err := WakeOnLAN(mac); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	// Old browsers post plain forms; send them back where they came from.
	if r.Header.Get("Accept") != "application/json" && r.Method == http.MethodPost {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	writeJSON(w, map[string]string{"status": "sent", "mac": mac})
}

func (h *Hub) handleStream(w http.ResponseWriter, r *http.Request) {
	id := filepath.Base(r.URL.Path)
	cam, ok := h.cameraByID(id)
	if !ok {
		http.NotFound(w, r)
		return
	}
	h.restreamer.ServeMJPEG(w, r, cam)
}

func (h *Hub) handleSnapshot(w http.ResponseWriter, r *http.Request) {
	id := filepath.Base(r.URL.Path)
	cam, ok := h.cameraByID(id)
	if !ok {
		http.NotFound(w, r)
		return
	}
	h.restreamer.ServeSnapshot(w, cam)
}

type dashboardData struct {
	Cameras []CameraConfig
	Hosts   []*Host
	Now     string
}

func (h *Hub) handleDashboard(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	tmpl, err := template.ParseFS(webFS, "web/index.html")
	if err != nil {
		http.Error(w, fmt.Sprintf("template: %v", err), http.StatusInternalServerError)
		return
	}

	hosts := h.scanner.Hosts()
	online := make([]*Host, 0, len(hosts))
	for _, host := range hosts {
		if host.Online {
			online = append(online, host)
		}
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	tmpl.Execute(w, dashboardData{
		Cameras: h.cameras(),
		Hosts:   online,
		Now:     time.Now().Format("15:04"),
	})
}
