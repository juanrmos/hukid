package console

import (
	"context"
	"net/http"
	"time"

	"hukid.local/platform/internal/adapters/privateapi"
	"hukid.local/platform/internal/authentication"
)

// VerificationHandler is the browser mount of the read-only verification
// views (VER-T11-e). It authenticates the console session cookie and delegates
// to the same reader as the Bearer API, which re-checks the live membership and
// the verification:read capability. It never starts a session: starting stays
// an operator action with fresh MFA.
type VerificationHandler struct {
	Auth       *MeHandler
	Management *privateapi.VerificationHandler
}

func (h *VerificationHandler) Register(mux *http.ServeMux) {
	mux.HandleFunc("/console/api/tenants/{tenantId}/verification-sessions", func(w http.ResponseWriter, r *http.Request) { h.serve(w, r, "list") })
	mux.HandleFunc("/console/api/tenants/{tenantId}/verification-sessions/{sessionId}", func(w http.ResponseWriter, r *http.Request) { h.serve(w, r, "get") })
}

func (h *VerificationHandler) serve(w http.ResponseWriter, r *http.Request, kind string) {
	if !privateapi.PrepareMethod(w, r, http.MethodGet) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	fail := func(err error) { privateapi.VerificationProblemFor(w, err, false) }
	if h == nil || h.Auth == nil || h.Management == nil {
		fail(authentication.ErrDependency)
		return
	}
	cookie := ""
	count := 0
	for _, c := range r.Cookies() {
		if c.Name == h.Auth.Sessions.Policy.CookieName {
			cookie = c.Value
			count++
		}
	}
	if count != 1 {
		fail(authentication.ErrSession)
		return
	}
	session, err := h.Auth.Sessions.Read(ctx, cookie)
	if err != nil {
		fail(err)
		return
	}
	operator, err := h.Auth.Verifier.VerifyOperator(ctx, session.AccessToken)
	if err != nil {
		fail(err)
		return
	}
	identity, err := h.Auth.Tenancy.Me(ctx, operator)
	if err != nil {
		fail(err)
		return
	}
	if identity.ActorID != session.ActorID {
		fail(authentication.ErrSession)
		return
	}
	// Browser reads must use the explicitly selected context, not a URL switch.
	if session.ActiveTenantID == "" || session.ActiveTenantID != r.PathValue("tenantId") {
		fail(authentication.ErrTenant)
		return
	}
	if err = h.Auth.Sessions.Touch(ctx, cookie); err != nil {
		fail(err)
		return
	}
	h.Management.ServeRead(w, r.WithContext(ctx), identity.ActorID, kind, false)
}
