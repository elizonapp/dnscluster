// PowerDNS Prometheus exporter (janeczku/powerdns_exporter), adapted:
// Labeled PowerDNS counters from the JSON API are set via .Set -> GaugeVec,
// not CounterVec (counters have no Set; upstream is incompatible with recent client_golang).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	_ "net/http/pprof"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/common/log"
)

const (
	namespace        = "powerdns"
	apiInfoEndpoint  = "servers/localhost"
	apiStatsEndpoint = "servers/localhost/statistics"
)

var (
	client = &http.Client{
		Transport: &http.Transport{
			Dial: func(netw, addr string) (net.Conn, error) {
				c, err := net.DialTimeout(netw, addr, 5*time.Second)
				if err != nil {
					return nil, err
				}
				if err := c.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
					return nil, err
				}
				return c, nil
			},
		},
	}
)

// ServerInfo is used to parse JSON data from 'server/localhost' endpoint
type ServerInfo struct {
	Kind       string `json:"type"`
	ID         string `json:"id"`
	URL        string `json:"url"`
	DaemonType string `json:"daemon_type"`
	Version    string `json:"version"`
	ConfigUrl  string `json:"config_url"`
	ZonesUrl   string `json:"zones_url"`
}

// StatsEntry is used to parse JSON data from 'server/localhost/statistics' endpoint
type StatsEntry struct {
	Name  string  `json:"name"`
	Kind  string  `json:"type"`
	Value float64 `json:"value,string"`
}

// Exporter collects PowerDNS stats from the given HostURL and exports them using
// the prometheus metrics package.
type Exporter struct {
	HostURL     *url.URL
	ServerType  string
	ApiKey      string
	mutex       sync.RWMutex
	up          prometheus.Gauge
	totalScrapes prometheus.Counter
	jsonParseFailures prometheus.Counter
	gaugeMetrics     map[int]prometheus.Gauge
	labeledGauges    map[int]*prometheus.GaugeVec
	gaugeDefs        []gaugeDefinition
	counterVecDefs []counterVecDefinition
}

func newLabeledGaugeVec(serverType, metricName, docString string, labelNames []string) *prometheus.GaugeVec {
	return prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: serverType,
			Name:      metricName,
			Help:      docString,
		},
		labelNames,
	)
}

func newGaugeMetric(serverType, metricName, docString string) prometheus.Gauge {
	return prometheus.NewGauge(
		prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: serverType,
			Name:      metricName,
			Help:      docString,
		},
	)
}

// NewExporter returns an initialized Exporter.
func NewExporter(apiKey, serverType string, hostURL *url.URL) *Exporter {
	var gdefs []gaugeDefinition
	var cdefs []counterVecDefinition

	gaugeMetrics := make(map[int]prometheus.Gauge)
	labeled := make(map[int]*prometheus.GaugeVec)

	switch serverType {
	case "recursor":
		gdefs = recursorGaugeDefs
		cdefs = recursorCounterVecDefs
	case "authoritative":
		gdefs = authoritativeGaugeDefs
		cdefs = authoritativeCounterVecDefs
	case "dnsdist":
		gdefs = dnsdistGaugeDefs
		cdefs = dnsdistCounterVecDefs
	}

	for _, def := range gdefs {
		gaugeMetrics[def.id] = newGaugeMetric(serverType, def.name, def.desc)
	}

	for _, def := range cdefs {
		labeled[def.id] = newLabeledGaugeVec(serverType, def.name, def.desc, []string{def.label})
	}

	return &Exporter{
		HostURL:    hostURL,
		ServerType: serverType,
		ApiKey:     apiKey,
		mutex:      sync.RWMutex{},
		up: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: namespace,
			Subsystem: serverType,
			Name:      "up",
			Help:      "Was the last scrape of PowerDNS successful.",
		}),
		totalScrapes: prometheus.NewCounter(prometheus.CounterOpts{
			Namespace: namespace,
			Subsystem: serverType,
			Name:      "exporter_total_scrapes",
			Help:      "Current total PowerDNS scrapes.",
		}),
		jsonParseFailures: prometheus.NewCounter(prometheus.CounterOpts{
			Namespace: namespace,
			Subsystem: serverType,
			Name:      "exporter_json_parse_failures",
			Help:      "Number of errors while parsing PowerDNS JSON stats.",
		}),
		gaugeMetrics:     gaugeMetrics,
		labeledGauges:    labeled,
		gaugeDefs:      gdefs,
		counterVecDefs: cdefs,
	}
}

// Describe implements prometheus.Collector.
func (e *Exporter) Describe(ch chan<- *prometheus.Desc) {
	for _, m := range e.labeledGauges {
		m.Describe(ch)
	}
	for _, m := range e.gaugeMetrics {
		ch <- m.Desc()
	}
	ch <- e.up.Desc()
	ch <- e.totalScrapes.Desc()
	ch <- e.jsonParseFailures.Desc()
}

// Collect implements prometheus.Collector.
func (e *Exporter) Collect(ch chan<- prometheus.Metric) {
	jsonStats := make(chan []StatsEntry)

	go e.scrape(jsonStats)

	e.mutex.Lock()
	defer e.mutex.Unlock()
	e.resetMetrics()
	statsMap := e.setMetrics(jsonStats)
	ch <- e.up
	ch <- e.totalScrapes
	ch <- e.jsonParseFailures
	e.collectMetrics(ch, statsMap)
}

func (e *Exporter) scrape(jsonStats chan<- []StatsEntry) {
	defer close(jsonStats)

	e.totalScrapes.Inc()

	var data []StatsEntry
	u := apiURL(e.HostURL, apiStatsEndpoint)
	err := getJSON(u, e.ApiKey, &data)
	if err != nil {
		e.up.Set(0)
		e.jsonParseFailures.Inc()
		log.Errorf("Error scraping PowerDNS: %v", err)
		return
	}

	e.up.Set(1)

	jsonStats <- data
}

func (e *Exporter) resetMetrics() {
	for _, m := range e.labeledGauges {
		m.Reset()
	}
}

func (e *Exporter) collectMetrics(ch chan<- prometheus.Metric, statsMap map[string]float64) {
	for _, m := range e.labeledGauges {
		m.Collect(ch)
	}
	for _, m := range e.gaugeMetrics {
		ch <- m
	}

	if e.ServerType == "recursor" {
		h, err := makeRecursorRTimeHistogram(statsMap)
		if err != nil {
			log.Errorf("Could not create response time histogram: %v", err)
			return
		}
		ch <- h
	}
}

func (e *Exporter) setMetrics(jsonStats <-chan []StatsEntry) (statsMap map[string]float64) {
	statsMap = make(map[string]float64)
	stats := <-jsonStats
	for _, s := range stats {
		statsMap[s.Name] = s.Value
	}
	if len(statsMap) == 0 {
		return
	}

	for _, def := range e.gaugeDefs {
		if value, ok := statsMap[def.key]; ok {
			if strings.HasSuffix(def.key, "latency") {
				value = value / 1000000
			}
			e.gaugeMetrics[def.id].Set(value)
		} else {
			log.Errorf("Expected PowerDNS stats key not found: %s", def.key)
			e.jsonParseFailures.Inc()
		}
	}

	for _, def := range e.counterVecDefs {
		for key, label := range def.labelMap {
			if value, ok := statsMap[key]; ok {
				e.labeledGauges[def.id].WithLabelValues(label).Set(value)
			} else {
				log.Errorf("Expected PowerDNS stats key not found: %s", key)
				e.jsonParseFailures.Inc()
			}
		}
	}
	return
}

func getServerInfo(hostURL *url.URL, apiKey string) (*ServerInfo, error) {
	var info ServerInfo
	u := apiURL(hostURL, apiInfoEndpoint)
	err := getJSON(u, apiKey, &info)
	if err != nil {
		return nil, err
	}

	return &info, nil
}

func getJSON(u, apiKey string, data interface{}) error {
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return err
	}

	req.Header.Add("X-API-Key", apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}

	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		content, err := io.ReadAll(resp.Body)
		if err != nil {
			return err
		}
		return fmt.Errorf("%s", string(content))
	}

	if err := json.NewDecoder(resp.Body).Decode(data); err != nil {
		return err
	}

	return nil
}

func apiURL(hostURL *url.URL, path string) string {
	endpointURI, _ := url.Parse(path)
	ret := hostURL.ResolveReference(endpointURI)
	return ret.String()
}

func main() {
	var (
		listenAddress = flag.String("listen-address", ":9120", "Address to listen on for web interface and telemetry.")
		metricsPath   = flag.String("metric-path", "/metrics", "Path under which to expose metrics.")
		apiURIFlag    = flag.String("api-url", "http://localhost:8001/", "Base-URL of PowerDNS authoritative server/recursor API.")
		apiKey        = flag.String("api-key", "", "PowerDNS API Key")
	)
	flag.Parse()

	hostURL, err := url.Parse(*apiURIFlag)
	if err != nil {
		log.Fatalf("Error parsing api-url: %v", err)
	}

	server, err := getServerInfo(hostURL, *apiKey)
	if err != nil {
		log.Fatalf("Could not fetch PowerDNS server info: %v", err)
	}

	exporter := NewExporter(*apiKey, server.DaemonType, hostURL)
	prometheus.MustRegister(exporter)

	log.Infof("Starting Server: %s", *listenAddress)
	http.Handle(*metricsPath, prometheus.Handler())
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`
<html>
<head><title>PowerDNS Exporter</title></head>
<body><h1>PowerDNS Exporter</h1>
<p><a href="` + *metricsPath + `">Metrics</a></p>
</body></html>`))
	})
	log.Fatal(http.ListenAndServe(*listenAddress, nil))
}
