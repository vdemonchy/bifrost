package schemas

import (
	"context"
	"testing"
)

func TestRoutingDebugContextReturnsOwnedInitialAttemptSnapshot(t *testing.T) {
	ctx := NewBifrostContext(context.Background(), NoDeadline)
	provider, model, tokens, outputTokens := "openai", "gpt-4o-mini", 17, 3
	requireSet := SetRoutingDebugOnContext(ctx, &BifrostRoutingDebug{
		ProviderUsed:       &provider,
		ModelUsed:          &model,
		InputTokens:        &tokens,
		OutputTokens:       &outputTokens,
		CountTowardBudgets: true,
	})
	if !requireSet {
		t.Fatal("SetRoutingDebugOnContext() = false")
	}

	first, ok := InitialAttemptRoutingDebugFromContext(ctx)
	if !ok {
		t.Fatal("InitialAttemptRoutingDebugFromContext() = false")
	}
	*first.InputTokens = 99
	*first.OutputTokens = 99
	second, ok := InitialAttemptRoutingDebugFromContext(ctx)
	if !ok || *second.InputTokens != 17 || *second.OutputTokens != 3 {
		t.Fatalf("owned snapshot = %v, want input=17 output=3", second)
	}
}

func TestInitialAttemptRoutingDebugRejectsRetriesAndFallbacks(t *testing.T) {
	provider, model, tokens := "openai", "text-embedding-3-small", 17
	for _, test := range []struct {
		name          string
		retryNumber   int
		fallbackIndex int
	}{
		{name: "retry", retryNumber: 1},
		{name: "fallback", fallbackIndex: 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx := NewBifrostContext(context.Background(), NoDeadline)
			ctx.SetValue(BifrostContextKeyNumberOfRetries, test.retryNumber)
			ctx.SetValue(BifrostContextKeyFallbackIndex, test.fallbackIndex)
			SetRoutingDebugOnContext(ctx, &BifrostRoutingDebug{
				ProviderUsed: &provider,
				ModelUsed:    &model,
				InputTokens:  &tokens,
			})
			if _, ok := InitialAttemptRoutingDebugFromContext(ctx); ok {
				t.Fatal("InitialAttemptRoutingDebugFromContext() = true")
			}
		})
	}
}

func TestSetRoutingDebugOnContextRejectsMalformedUsage(t *testing.T) {
	provider, model := "openai", "gpt-4o-mini"
	negativeOutput := -1
	for _, test := range []struct {
		name         string
		inputTokens  int
		outputTokens *int
	}{
		{name: "negative input", inputTokens: -1},
		{name: "negative output", outputTokens: &negativeOutput},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx := NewBifrostContext(context.Background(), NoDeadline)
			if SetRoutingDebugOnContext(ctx, &BifrostRoutingDebug{
				ProviderUsed: &provider,
				ModelUsed:    &model,
				InputTokens:  &test.inputTokens,
				OutputTokens: test.outputTokens,
			}) {
				t.Fatal("SetRoutingDebugOnContext() accepted malformed usage")
			}
		})
	}
}
