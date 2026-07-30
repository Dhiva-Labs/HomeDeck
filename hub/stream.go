package main

import (
	"bufio"
	"bytes"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"sync"
	"time"
)

// CameraConfig is one camera the hub can restream.
type CameraConfig struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	StreamURL string `json:"streamUrl"`
	Room      string `json:"room,omitempty"`
}

// Restreamer turns an RTSP camera into an MJPEG stream.
//
// This is the whole reason ancient devices work: a 2012 Android browser or an
// iOS 6 iPad cannot play RTSP or H.264-over-HLS, but every browser ever built
// renders multipart MJPEG in a plain <img> tag with no JavaScript at all.
//
// One ffmpeg process per camera is shared by all viewers, so ten wall panels
// watching the same camera cost one transcode, not ten.
type Restreamer struct {
	mu       sync.Mutex
	sessions map[string]*session
	fps      int
	width    int
	quality  int
}

type session struct {
	mu      sync.RWMutex
	clients map[chan []byte]struct{}
	cmd     *exec.Cmd
	stop    chan struct{}
	latest  []byte
}

func NewRestreamer(fps, width, quality int) *Restreamer {
	return &Restreamer{
		sessions: make(map[string]*session),
		fps:      fps,
		width:    width,
		quality:  quality,
	}
}

// ServeMJPEG streams camera to w as multipart/x-mixed-replace until the client
// disconnects.
func (r *Restreamer) ServeMJPEG(w http.ResponseWriter, req *http.Request, cam CameraConfig) {
	frames := make(chan []byte, 2)
	sess := r.subscribe(cam, frames)
	defer r.unsubscribe(cam.ID, frames)

	w.Header().Set("Content-Type", "multipart/x-mixed-replace; boundary=frame")
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Connection", "close")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	// Send the last known frame straight away so the panel paints something
	// instead of a blank box while ffmpeg warms up.
	if first := sess.lastFrame(); first != nil {
		if err := writeFrame(w, first); err != nil {
			return
		}
		flusher.Flush()
	}

	for {
		select {
		case <-req.Context().Done():
			return
		case frame, ok := <-frames:
			if !ok {
				return
			}
			if err := writeFrame(w, frame); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// ServeSnapshot writes a single JPEG — used by grid thumbnails, which must
// never hold a connection open.
func (r *Restreamer) ServeSnapshot(w http.ResponseWriter, cam CameraConfig) {
	frames := make(chan []byte, 1)
	sess := r.subscribe(cam, frames)
	defer r.unsubscribe(cam.ID, frames)

	frame := sess.lastFrame()
	if frame == nil {
		select {
		case frame = <-frames:
		case <-time.After(10 * time.Second):
			http.Error(w, "camera did not produce a frame", http.StatusGatewayTimeout)
			return
		}
	}

	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(frame)
}

func writeFrame(w http.ResponseWriter, frame []byte) error {
	if _, err := fmt.Fprintf(w,
		"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n",
		len(frame)); err != nil {
		return err
	}
	if _, err := w.Write(frame); err != nil {
		return err
	}
	_, err := w.Write([]byte("\r\n"))
	return err
}

func (r *Restreamer) subscribe(cam CameraConfig, ch chan []byte) *session {
	r.mu.Lock()
	defer r.mu.Unlock()

	sess, ok := r.sessions[cam.ID]
	if !ok {
		sess = &session{
			clients: make(map[chan []byte]struct{}),
			stop:    make(chan struct{}),
		}
		r.sessions[cam.ID] = sess
		go r.pump(cam, sess)
	}

	sess.mu.Lock()
	sess.clients[ch] = struct{}{}
	sess.mu.Unlock()
	return sess
}

func (r *Restreamer) unsubscribe(id string, ch chan []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()

	sess, ok := r.sessions[id]
	if !ok {
		return
	}

	sess.mu.Lock()
	delete(sess.clients, ch)
	remaining := len(sess.clients)
	sess.mu.Unlock()

	// No viewers left: kill ffmpeg rather than transcode into the void.
	if remaining == 0 {
		close(sess.stop)
		delete(r.sessions, id)
	}
}

func (s *session) lastFrame() []byte {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.latest
}

func (s *session) broadcast(frame []byte) {
	s.mu.Lock()
	s.latest = frame
	clients := make([]chan []byte, 0, len(s.clients))
	for ch := range s.clients {
		clients = append(clients, ch)
	}
	s.mu.Unlock()

	for _, ch := range clients {
		// Never block on a slow panel; it just misses this frame.
		select {
		case ch <- frame:
		default:
		}
	}
}

// pump runs ffmpeg and splits its MJPEG output into frames, restarting it if
// the camera drops until the last viewer leaves.
func (r *Restreamer) pump(cam CameraConfig, sess *session) {
	for {
		select {
		case <-sess.stop:
			return
		default:
		}

		args := []string{
			"-rtsp_transport", "tcp",
			"-i", cam.StreamURL,
			"-an",
			"-r", fmt.Sprint(r.fps),
			"-vf", fmt.Sprintf("scale=%d:-2", r.width),
			"-q:v", fmt.Sprint(r.quality),
			"-f", "mjpeg",
			"-",
		}
		cmd := exec.Command("ffmpeg", args...)
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			log.Printf("restream %s: stdout pipe: %v", cam.ID, err)
			return
		}
		cmd.Stderr = nil

		if err := cmd.Start(); err != nil {
			log.Printf("restream %s: start ffmpeg: %v", cam.ID, err)
			return
		}

		sess.mu.Lock()
		sess.cmd = cmd
		sess.mu.Unlock()

		go func() {
			<-sess.stop
			if cmd.Process != nil {
				cmd.Process.Kill()
			}
		}()

		splitFrames(bufio.NewReaderSize(stdout, 1<<20), sess.broadcast)
		cmd.Wait()

		select {
		case <-sess.stop:
			return
		case <-time.After(3 * time.Second):
			log.Printf("restream %s: ffmpeg exited, retrying", cam.ID)
		}
	}
}

var (
	jpegSOI = []byte{0xFF, 0xD8}
	jpegEOI = []byte{0xFF, 0xD9}
)

// splitFrames carves complete JPEGs out of ffmpeg's concatenated MJPEG output
// by scanning for start- and end-of-image markers.
func splitFrames(r *bufio.Reader, emit func([]byte)) {
	var buf bytes.Buffer
	chunk := make([]byte, 32*1024)

	for {
		n, err := r.Read(chunk)
		if n > 0 {
			buf.Write(chunk[:n])

			for {
				data := buf.Bytes()
				start := bytes.Index(data, jpegSOI)
				if start < 0 {
					break
				}
				end := bytes.Index(data[start+2:], jpegEOI)
				if end < 0 {
					break
				}
				frameEnd := start + 2 + end + 2
				frame := make([]byte, frameEnd-start)
				copy(frame, data[start:frameEnd])
				emit(frame)

				rest := make([]byte, len(data)-frameEnd)
				copy(rest, data[frameEnd:])
				buf.Reset()
				buf.Write(rest)
			}
		}
		if err != nil {
			return
		}
	}
}
