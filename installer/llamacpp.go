// Package installer fetches the lemonade pre-built llama-server binary
// (native ROCm gfx1150, ROCm 7 bundled) from GitHub releases.
package installer

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

const releaseAPI = "https://api.github.com/repos/lemonade-sdk/llamacpp-rocm/releases/latest"

// DownloadZip fetches the latest gfx1150 Ubuntu zip into destDir.
// If the file already exists and its size matches the release asset size,
// the download is skipped. A partial download is detected and re-fetched.
// Returns the path to the zip.
func DownloadZip(destDir string, logFn func(string)) (string, error) {
	logFn("Hämtar senaste lemonade release-info från GitHub...")
	assetURL, assetName, assetSize, err := latestGFX1150Asset()
	if err != nil {
		return "", fmt.Errorf("release-info: %w", err)
	}

	out := filepath.Join(destDir, assetName)

	if stat, err := os.Stat(out); err == nil {
		if stat.Size() == assetSize {
			logFn(fmt.Sprintf("Redan nedladdad, storlek OK (%d MB): %s", assetSize>>20, out))
			return out, nil
		}
		logFn(fmt.Sprintf("Ofullständig fil (%d / %d MB) — laddar om...", stat.Size()>>20, assetSize>>20))
		os.Remove(out)
	}

	if err := os.MkdirAll(destDir, 0755); err != nil {
		return "", err
	}

	logFn(fmt.Sprintf("Laddar ner %s (%d MB)...", assetName, assetSize>>20))
	resp, err := http.Get(assetURL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %s", resp.Status)
	}

	// Write to a temp file; rename on success so a partial write is never
	// left in place with the final filename.
	tmp := out + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return "", err
	}

	pr := &progressReader{r: resp.Body, total: assetSize, logFn: logFn}
	written, copyErr := io.Copy(f, pr)
	f.Close()
	if copyErr != nil {
		os.Remove(tmp)
		return "", copyErr
	}

	if written != assetSize {
		os.Remove(tmp)
		return "", fmt.Errorf("nedladdning avbruten: fick %d av %d bytes", written, assetSize)
	}

	if err := os.Rename(tmp, out); err != nil {
		os.Remove(tmp)
		return "", err
	}

	logFn(fmt.Sprintf("Sparad: %s (%d MB)", out, written>>20))
	return out, nil
}

// --- GitHub API -------------------------------------------------------

type githubRelease struct {
	Assets []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
		Size               int64  `json:"size"`
	} `json:"assets"`
}

func latestGFX1150Asset() (url, name string, size int64, err error) {
	resp, err := http.Get(releaseAPI)
	if err != nil {
		return "", "", 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", 0, fmt.Errorf("GitHub API svarade %s", resp.Status)
	}

	var rel githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return "", "", 0, err
	}

	for _, a := range rel.Assets {
		n := strings.ToLower(a.Name)
		if strings.Contains(n, "ubuntu") &&
			strings.Contains(n, "gfx1150") &&
			strings.HasSuffix(n, ".zip") {
			return a.BrowserDownloadURL, a.Name, a.Size, nil
		}
	}
	return "", "", 0, fmt.Errorf("ingen ubuntu-gfx1150.zip i senaste release")
}

// --- Progress ---------------------------------------------------------

type progressReader struct {
	r       io.Reader
	total   int64
	read    int64
	logFn   func(string)
	lastPct int
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.read += int64(n)
	if p.total > 0 {
		pct := int(p.read * 100 / p.total)
		if pct >= p.lastPct+10 {
			p.lastPct = pct
			p.logFn(fmt.Sprintf("  %d%%  (%d / %d MB)", pct, p.read>>20, p.total>>20))
		}
	}
	return n, err
}
