package console

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"hukid.local/platform/internal/adapters/privateapi"
	a "hukid.local/platform/internal/authentication"
)

func verificationMux(t *testing.T, ready bool) (*http.ServeMux, string) {
	t.Helper()
	f, err := os.Open("../../../config/auth.test.json")
	if err != nil {
		t.Fatal(err)
	}
	policy, err := a.LoadPolicy(f, "test")
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	h := &VerificationHandler{Auth: &MeHandler{Sessions: &a.SessionService{Policy: policy, Now: time.Now}}}
	if ready {
		// No store, reader or tenancy: any request that got past the cookie checks would panic.
		h.Management = &privateapi.VerificationHandler{}
	}
	mux := http.NewServeMux()
	h.Register(mux)
	return mux, policy.CookieName
}

func TestBrowserVerificationReadsRejectBeforeAnyStorage(t *testing.T) {
	mux, cookie := verificationMux(t, true)
	paths := []string{
		"/console/api/tenants/t1/verification-sessions",
		"/console/api/tenants/t1/verification-sessions/7a7f8c3e-5b0e-4a6b-9a39-0d6c1f3c9a11",
	}
	for _, path := range paths {
		cases := map[string]func(*http.Request){
			"no cookie":        func(*http.Request) {},
			"duplicate cookie": func(r *http.Request) { r.AddCookie(&http.Cookie{Name: cookie, Value: "a"}); r.AddCookie(&http.Cookie{Name: cookie, Value: "b"}) },
			"foreign cookie":   func(r *http.Request) { r.AddCookie(&http.Cookie{Name: "other", Value: "a"}) },
			"bearer only":      func(r *http.Request) { r.Header.Set("Authorization", "Bearer valid") },
		}
		for name, mutate := range cases {
			req := httptest.NewRequest(http.MethodGet, path, nil)
			mutate(req)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized || rec.Header().Get("WWW-Authenticate") != "" || rec.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("%s %s: status %d challenge %q cache %q", path, name, rec.Code, rec.Header().Get("WWW-Authenticate"), rec.Header().Get("Cache-Control"))
			}
		}
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
			req := httptest.NewRequest(method, path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s %s: status %d", method, path, rec.Code)
			}
		}
	}
}

func TestBrowserVerificationReadsFailClosedWithoutTheModule(t *testing.T) {
	mux, _ := verificationMux(t, false)
	req := httptest.NewRequest(http.MethodGet, "/console/api/tenants/t1/verification-sessions", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d", rec.Code)
	}
}
