package main

import (
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Models

type Product struct {
	ProductID    *int32  `json:"product_id" binding:"required,min=1"`
	Name         *string `json:"name,omitempty" binding:"omitempty,max=200"`
	SKU          *string `json:"sku" binding:"required,min=1,max=100"`
	Manufacturer *string `json:"manufacturer" binding:"required,min=1,max=200"`
	CategoryID   *int32  `json:"category_id" binding:"required,min=1"`
	Weight       *int32  `json:"weight" binding:"required,min=0"`
	SomeOtherID  *int32  `json:"some_other_id" binding:"required,min=1"`
}

type SearchResult struct {
	Products   []Product `json:"products"`
	TotalFound int32     `json:"total_found"`
	SearchTime string    `json:"search_time,omitempty"`
}

type Error struct {
	Error   string `json:"error"`
	Message string `json:"message"`
	Details string `json:"details,omitempty"`
}

// Store

var (
	products = map[int32]Product{}
	// Insertion order of product IDs, so a search can walk a fixed-size window of the catalog
	productIDs []int32
	mu         sync.RWMutex
)

// Search tuning

const (
	numProducts       = 100_000
	productsPerSearch = 100 // fixed work per request: every search checks exactly this many products
	maxSearchResults  = 20
	maxQueryLength    = 100
)

// Products only carry category IDs; category ID n maps to categories[(n-1) % len(categories)]
var (
	categories = []string{"Electronics", "Books", "Home", "Garden", "Toys", "Sports", "Clothing", "Beauty", "Automotive", "Grocery"}
	brands     = []string{"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Omega", "Nova", "Apex", "Vertex"}
)

// Rotates each search's starting point so successive searches cover the whole catalog
var searchCursor atomic.Uint64

// Observability: RED signals (rate, errors, duration) per endpoint

var (
	requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Requests handled, by endpoint and status code.",
	}, []string{"method", "endpoint", "status"})

	errorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_request_errors_total",
		Help: "Requests that returned a non-2xx status, by endpoint and status code.",
	}, []string{"method", "endpoint", "status"})

	requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name: "http_request_duration_seconds",
		Help: "Time spent handling a request, by endpoint.",
		// 50µs to ~1.6s: requests take well under the default buckets' 5ms minimum
		Buckets: prometheus.ExponentialBuckets(0.00005, 2, 16),
	}, []string{"method", "endpoint"})

	// Every search should add exactly productsPerSearch; rate(checked) / rate(searches) verifies it
	productsCheckedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "search_products_checked_total",
		Help: "Products examined by /products/search.",
	})

	logger = slog.New(slog.NewJSONHandler(os.Stdout, nil))
)

// observe records metrics and writes one JSON log line per request.
func observe(c *gin.Context) {
	start := time.Now()
	c.Next()
	duration := time.Since(start)

	// Route template (e.g. /products/:productId), not the raw path, so IDs don't explode label cardinality
	endpoint := c.FullPath()
	if endpoint == "" {
		endpoint = "unmatched"
	}
	method := c.Request.Method
	status := c.Writer.Status()
	statusLabel := strconv.Itoa(status)

	requestsTotal.WithLabelValues(method, endpoint, statusLabel).Inc()
	if status < 200 || status > 299 {
		errorsTotal.WithLabelValues(method, endpoint, statusLabel).Inc()
	}
	requestDuration.WithLabelValues(method, endpoint).Observe(duration.Seconds())

	attrs := []any{
		"method", method,
		"endpoint", endpoint,
		"path", c.Request.URL.Path,
		"status", status,
		"duration_ms", float64(duration.Microseconds()) / 1000,
	}
	if p, ok := c.Get("panic"); ok {
		attrs = append(attrs, "error", p)
	}
	logger.Info("request", attrs...)
}

// Data generation

func ptr[T any](v T) *T { return &v }

// generateProducts fills the store with numProducts products named "Product <Brand> <ID>".
func generateProducts() {
	productIDs = make([]int32, 0, numProducts)
	for i := int32(1); i <= numProducts; i++ {
		// Brand advances once per full category cycle, so brands and categories don't move in lockstep
		brand := brands[int(i)/len(categories)%len(brands)]
		products[i] = Product{
			ProductID:    ptr(i),
			Name:         ptr(fmt.Sprintf("Product %s %d", brand, i)),
			SKU:          ptr(fmt.Sprintf("SKU-%06d", i)),
			Manufacturer: ptr(brand + " Corporation"),
			CategoryID:   ptr(i%int32(len(categories)) + 1),
			Weight:       ptr(i % 5000),
			SomeOtherID:  ptr(i%1000 + 1),
		}
		productIDs = append(productIDs, i)
	}
}

// Helpers

func categoryName(id int32) string {
	return categories[int(id-1)%len(categories)]
}

// matches reports whether lowerQuery appears in the product's name or category name, ignoring case.
func matches(p Product, lowerQuery string) bool {
	if p.Name != nil && strings.Contains(strings.ToLower(*p.Name), lowerQuery) {
		return true
	}
	return strings.Contains(strings.ToLower(categoryName(*p.CategoryID)), lowerQuery)
}

func parseProductID(c *gin.Context) (int32, bool) {
	id, err := strconv.ParseInt(c.Param("productId"), 10, 32)
	if err != nil || id < 1 {
		c.JSON(http.StatusNotFound, Error{"NOT_FOUND", "Product not found", "product ID must be a positive 32-bit integer"})
		return 0, false
	}
	return int32(id), true
}

// Handlers

func getProduct(c *gin.Context) {
	id, ok := parseProductID(c)
	if !ok {
		return
	}

	mu.RLock()
	product, found := products[id]
	mu.RUnlock()

	if !found {
		c.JSON(http.StatusNotFound, Error{"NOT_FOUND", "Product not found", ""})
		return
	}
	c.JSON(http.StatusOK, product)
}

func addProductDetails(c *gin.Context) {
	id, ok := parseProductID(c)
	if !ok {
		return
	}

	var product Product
	if err := c.ShouldBindJSON(&product); err != nil {
		c.JSON(http.StatusBadRequest, Error{"INVALID_INPUT", "The provided input data is invalid", err.Error()})
		return
	}
	if *product.ProductID != id {
		c.JSON(http.StatusBadRequest, Error{"INVALID_INPUT", "The provided input data is invalid", "product_id in body must match product ID in path"})
		return
	}

	mu.Lock()
	if _, exists := products[id]; !exists {
		productIDs = append(productIDs, id)
	}
	products[id] = product
	mu.Unlock()

	c.Status(http.StatusNoContent)
}

func searchProducts(c *gin.Context) {
	start := time.Now()

	query, present := c.GetQuery("q")
	if !present || query == "" {
		c.JSON(http.StatusBadRequest, Error{"INVALID_INPUT", "The provided input data is invalid", "query parameter q is required"})
		return
	}
	if utf8.RuneCountInString(query) > maxQueryLength {
		c.JSON(http.StatusBadRequest, Error{"INVALID_INPUT", "The provided input data is invalid", "query parameter q must be at most 100 characters"})
		return
	}
	lowerQuery := strings.ToLower(query)

	// Check exactly productsPerSearch products, even after maxSearchResults are found, so every search costs the same
	results := make([]Product, 0, maxSearchResults)
	checked := 0
	mu.RLock()
	n := len(productIDs)
	offset := int(searchCursor.Add(productsPerSearch) % uint64(n))
	for ; checked < productsPerSearch && checked < n; checked++ {
		p := products[productIDs[(offset+checked)%n]]
		if matches(p, lowerQuery) && len(results) < maxSearchResults {
			results = append(results, p)
		}
	}
	mu.RUnlock()
	productsCheckedTotal.Add(float64(checked))

	c.JSON(http.StatusOK, SearchResult{
		Products:   results,
		TotalFound: int32(len(results)),
		SearchTime: time.Since(start).String(),
	})
}

// Main

func main() {
	// Release mode keeps Gin's debug lines out of stdout, so every log line is JSON
	gin.SetMode(gin.ReleaseMode)
	generateProducts()
	r := gin.New()

	// Scraped by Prometheus; registered before the middleware so scrapes aren't counted as traffic
	r.GET("/metrics", gin.WrapH(promhttp.Handler()))

	r.Use(observe)
	// The panic goes into the request's JSON log line instead of a stack trace
	r.Use(gin.CustomRecoveryWithWriter(io.Discard, func(c *gin.Context, err any) {
		c.Set("panic", fmt.Sprint(err))
		c.AbortWithStatusJSON(http.StatusInternalServerError, Error{"INTERNAL_ERROR", "Internal server error", ""})
	}))
	r.Use(func(c *gin.Context) {
		if c.GetHeader("X-Simulate-Error") == "true" {
			panic("simulated error")
		}
	})

	r.GET("/products/search", searchProducts)
	r.GET("/products/:productId", getProduct)
	r.POST("/products/:productId/details", addProductDetails)

	r.Run(":8080")
}
