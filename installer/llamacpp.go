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
// Skips if a matching file already exists. Returns the path to the zip.
func DownloadZip(destDir string, logFn func(string)) (string, error) {
	logFn("Hämtar senaste lemonade release-info från GitHub...")
	assetURL, assetName, err := latestGFX1150URL()
	if err != nil {
		return "", fmt.Errorf("release-info: %w", err)
	}

	out := filepath.Join(destDir, assetName)
	if _, err := os.Stat(out); err == nil {
		logFn(fmt.Sprintf("Redan nedladdad: %s", out))
		return out, nil
	}

	if err := os.MkdirAll(destDir, 0755); err != nil {
		return "", err
	}

	logFn(fmt.Sprintf("Laddar ner %s (~440 MB)...", assetName))
	resp, err := http.Get(assetURL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %s", resp.Status)
	}

	f, err := os.Create(out)
	if err != nil {
		return "", err
	}
	defer f.Close()

	pr := &progressReader{r: resp.Body, total: resp.ContentLength, logFn: logFn}
	if _, err := io.Copy(f, pr); err != nil {
		os.Remove(out)
		return "", err
	}
	logFn(fmt.Sprintf("Sparad: %s", out))
	return out, nil
}

// --- GitHub API -------------------------------------------------------

type githubRelease struct {
	Assets []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
	} `json:"assets"`
}

func latestGFX1150URL() (url, name string, err error) {
	resp, err := http.Get(releaseAPI)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("GitHub API svarade %s", resp.Status)
	}

	var rel githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return "", "", err
	}

	for _, a := range rel.Assets {
		n := strings.ToLower(a.Name)
		if strings.Contains(n, "ubuntu") &&
			strings.Contains(n, "gfx1150") &&
			strings.HasSuffix(n, ".zip") {
			return a.BrowserDownloadURL, a.Name, nil
		}
	}
	return "", "", fmt.Errorf("ingen ubuntu-gfx1150.zip i senaste release")
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
