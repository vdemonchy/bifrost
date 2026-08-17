package runware

import (
	"strings"
	"testing"

	schemas "github.com/maximhq/bifrost/core/schemas"
)

func upscaleEditRequest(extraParams map[string]interface{}) *schemas.BifrostImageEditRequest {
	return &schemas.BifrostImageEditRequest{
		Model: "topazlabs:wonder@3.5",
		Input: &schemas.ImageEditInput{Images: []schemas.ImageInput{{Image: []byte("fake-image-bytes")}}},
		Params: &schemas.ImageEditParameters{
			Type:        new("upscale"),
			ExtraParams: extraParams,
		},
	}
}

// type=upscale switches the edit path to the upscale task: the image moves under inputs, and the
// imageInference-only fields (prompt, dimensions, steps) are left unset since Runware rejects them.
func TestToRunwareImageEditRequest_Upscale(t *testing.T) {
	out, err := ToRunwareImageEditRequest(upscaleEditRequest(nil))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.TaskType != taskTypeUpscale {
		t.Fatalf("taskType = %q, want %q", out.TaskType, taskTypeUpscale)
	}
	if out.Inputs == nil || out.Inputs.Image == nil || !strings.HasPrefix(*out.Inputs.Image, "data:") {
		t.Fatalf("expected inputs.image data URI, got %+v", out.Inputs)
	}
	if out.SeedImage != nil {
		t.Fatalf("seedImage must stay unset on upscale, got %q", *out.SeedImage)
	}
	if out.PositivePrompt != nil || out.Width != nil || out.Height != nil || out.Steps != nil {
		t.Fatalf("prompt/width/height/steps must stay unset on upscale, got %+v", out)
	}
	if out.IncludeCost == nil || !*out.IncludeCost {
		t.Fatalf("expected includeCost=true so the task cost is reported")
	}
}

// Upscaler fields arrive as multipart form strings; they are coerced to typed properties and
// removed from ExtraParams so passthrough does not also emit them verbatim.
func TestToRunwareImageEditRequest_UpscaleExtraParams(t *testing.T) {
	extraParams := map[string]interface{}{
		"upscaleFactor":    "4",
		"targetMegapixels": "16",
		"settings":         `{"enhancementStrength":"high"}`,
		"unrelated":        "keep-me",
	}

	out, err := ToRunwareImageEditRequest(upscaleEditRequest(extraParams))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.UpscaleFactor == nil || *out.UpscaleFactor != 4 {
		t.Fatalf("upscaleFactor = %v, want 4", out.UpscaleFactor)
	}
	if out.TargetMegapixels == nil || *out.TargetMegapixels != 16 {
		t.Fatalf("targetMegapixels = %v, want 16", out.TargetMegapixels)
	}
	if out.Settings["enhancementStrength"] != "high" {
		t.Fatalf("settings = %+v, want enhancementStrength=high", out.Settings)
	}
	for _, consumed := range []string{"upscaleFactor", "targetMegapixels", "settings"} {
		if _, ok := out.ExtraParams[consumed]; ok {
			t.Fatalf("%q should be consumed from ExtraParams, got %+v", consumed, out.ExtraParams)
		}
	}
	if out.ExtraParams["unrelated"] != "keep-me" {
		t.Fatalf("unrecognised extra params must pass through, got %+v", out.ExtraParams)
	}
}

// type=background_removal (and its aliases) selects the removeBackground task, which shares the
// tool envelope with upscale but takes none of the upscaler-specific fields.
func TestToRunwareImageEditRequest_RemoveBackground(t *testing.T) {
	for _, alias := range []string{"background_removal", "remove_background", "remove_bg", "Remove-Background"} {
		req := upscaleEditRequest(nil)
		req.Model = "runware:109@1"
		req.Params.Type = &alias

		out, err := ToRunwareImageEditRequest(req)
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", alias, err)
		}
		if out.TaskType != taskTypeRemoveBackground {
			t.Fatalf("%s: taskType = %q, want %q", alias, out.TaskType, taskTypeRemoveBackground)
		}
		if out.Inputs == nil || out.Inputs.Image == nil {
			t.Fatalf("%s: expected inputs.image, got %+v", alias, out.Inputs)
		}
		if out.UpscaleFactor != nil || out.TargetMegapixels != nil {
			t.Fatalf("%s: upscaler fields must stay unset, got %+v", alias, out)
		}
		if out.PositivePrompt != nil || out.Width != nil || out.Height != nil {
			t.Fatalf("%s: prompt/dimensions must stay unset, got %+v", alias, out)
		}
		if out.IncludeCost == nil || !*out.IncludeCost {
			t.Fatalf("%s: expected includeCost=true", alias)
		}
	}
}

// removeBackground tuning lives in settings (runware models) or providerSettings (bria); both are
// consumed out of extra params so they reach the wire as nested objects.
func TestToRunwareImageEditRequest_RemoveBackgroundSettings(t *testing.T) {
	req := upscaleEditRequest(map[string]interface{}{
		"settings":         `{"returnOnlyMask":true,"rgba":[255,255,255,0]}`,
		"providerSettings": map[string]interface{}{"bria": map[string]interface{}{"preserveAlpha": true}},
		"upscaleFactor":    "4",
	})
	req.Model = "bria:2@1"
	req.Params.Type = new("background_removal")

	out, err := ToRunwareImageEditRequest(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.Settings["returnOnlyMask"] != true {
		t.Fatalf("settings = %+v, want returnOnlyMask=true", out.Settings)
	}
	if out.ProviderSettings["bria"] == nil {
		t.Fatalf("providerSettings = %+v, want a bria entry", out.ProviderSettings)
	}
	// upscaleFactor is meaningless here, so it stays in extra params rather than being promoted.
	if out.UpscaleFactor != nil {
		t.Fatalf("upscaleFactor must not be promoted for removeBackground, got %v", *out.UpscaleFactor)
	}
	if out.ExtraParams["upscaleFactor"] != "4" {
		t.Fatalf("unpromoted extra params must pass through, got %+v", out.ExtraParams)
	}
}

// A settings object supplied by a JSON caller is used as-is, without a string round-trip.
func TestToRunwareImageEditRequest_UpscaleSettingsObject(t *testing.T) {
	out, err := ToRunwareImageEditRequest(upscaleEditRequest(map[string]interface{}{
		"settings": map[string]interface{}{"realism": true},
	}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.Settings["realism"] != true {
		t.Fatalf("settings = %+v, want realism=true", out.Settings)
	}
}

// Edits without type=upscale keep using imageInference with a top-level seedImage.
func TestToRunwareImageEditRequest_NonUpscaleUnchanged(t *testing.T) {
	out, err := ToRunwareImageEditRequest(&schemas.BifrostImageEditRequest{
		Model: "runware:101@1",
		Input: &schemas.ImageEditInput{
			Images: []schemas.ImageInput{{Image: []byte("fake-image-bytes")}},
			Prompt: "make it night",
		},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.TaskType != taskTypeImageInference {
		t.Fatalf("taskType = %q, want %q", out.TaskType, taskTypeImageInference)
	}
	if out.SeedImage == nil {
		t.Fatalf("expected seedImage to remain top-level for imageInference")
	}
	if out.Inputs != nil {
		t.Fatalf("inputs must stay unset for imageInference, got %+v", out.Inputs)
	}
}

// type=mask selects the imageMasking task; detector settings ride along in settings.
func TestToRunwareImageEditRequest_Mask(t *testing.T) {
	for _, alias := range []string{"mask", "segmentation", "Mask"} {
		req := upscaleEditRequest(map[string]interface{}{
			"settings": `{"confidence":0.7,"maskPadding":20,"maxDetections":4}`,
		})
		req.Model = "runware:35@1"
		req.Params.Type = &alias

		out, err := ToRunwareImageEditRequest(req)
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", alias, err)
		}
		if out.TaskType != taskTypeImageMasking {
			t.Fatalf("%s: taskType = %q, want %q", alias, out.TaskType, taskTypeImageMasking)
		}
		if out.Inputs == nil || out.Inputs.Image == nil {
			t.Fatalf("%s: expected inputs.image, got %+v", alias, out.Inputs)
		}
		if out.Settings["confidence"] != 0.7 {
			t.Fatalf("%s: settings = %+v, want confidence=0.7", alias, out.Settings)
		}
	}
}

// Masking and ControlNet preprocessing return their artifact under maskImage*/guideImage*; reading
// only image* would emit an entry with no URL at all. Detections ride along on the same entry.
func TestToBifrostImageGenerationResponse_OutputFamilies(t *testing.T) {
	t.Run("maskImage with detections", func(t *testing.T) {
		out, err := ToBifrostImageGenerationResponse(&RunwareResponse{Data: []RunwareResult{{
			TaskUUID:     "mask-1",
			MaskImageURL: "https://x/mask.png",
			Detections:   []RunwareDetection{{XMin: 1, YMin: 2, XMax: 3, YMax: 4}},
		}}})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if out.Data[0].URL != "https://x/mask.png" {
			t.Fatalf("mask URL not surfaced: %+v", out.Data[0])
		}
		if len(out.Data[0].Detections) != 1 || out.Data[0].Detections[0].XMax != 3 {
			t.Fatalf("detections not surfaced: %+v", out.Data[0].Detections)
		}
	})

	t.Run("guideImage base64", func(t *testing.T) {
		out, err := ToBifrostImageGenerationResponse(&RunwareResponse{Data: []RunwareResult{{
			TaskUUID:             "guide-1",
			GuideImageBase64Data: "Zm9v",
		}}})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if out.Data[0].B64JSON != "Zm9v" {
			t.Fatalf("guide image not surfaced: %+v", out.Data[0])
		}
	})

	t.Run("image family still wins", func(t *testing.T) {
		out, err := ToBifrostImageGenerationResponse(&RunwareResponse{Data: []RunwareResult{{
			TaskUUID: "img-1", ImageURL: "https://x/a.png", MaskImageURL: "https://x/mask.png",
		}}})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if out.Data[0].URL != "https://x/a.png" {
			t.Fatalf("image family must take precedence, got %+v", out.Data[0])
		}
		if len(out.Data[0].Detections) != 0 {
			t.Fatalf("expected no detections, got %+v", out.Data[0].Detections)
		}
	})
}

// Runware only returns a per-task cost when the request opts in, so every generated task sets
// includeCost; without it the response carries no cost and the task is billed as $0.
func TestToRunwareRequests_AlwaysIncludeCost(t *testing.T) {
	gen, err := ToRunwareImageGenerationRequest(&schemas.BifrostImageGenerationRequest{
		Model: "runware:101@1",
		Input: &schemas.ImageGenerationInput{Prompt: "a teapot"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	edit, err := ToRunwareImageEditRequest(&schemas.BifrostImageEditRequest{
		Model: "runware:101@1",
		Input: &schemas.ImageEditInput{
			Images: []schemas.ImageInput{{Image: []byte("fake-image-bytes")}},
			Prompt: "make it night",
		},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	upscale, err := ToRunwareImageEditRequest(upscaleEditRequest(nil))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	for name, req := range map[string]*RunwareInferenceRequest{
		"generation": gen, "edit": edit, "upscale": upscale,
	} {
		if req.IncludeCost == nil || !*req.IncludeCost {
			t.Fatalf("%s: expected includeCost=true, got %v", name, req.IncludeCost)
		}
	}
}

// Runware reports per-task cost (when includeCost is set); it is summed across results and surfaced
// as the provider-reported image cost so pricing uses it verbatim.
func TestToBifrostImageGenerationResponse_Cost(t *testing.T) {
	resp := &RunwareResponse{
		Data: []RunwareResult{
			{TaskUUID: "img-1", ImageURL: "https://x/1.jpg", Cost: 0.0006},
			{TaskUUID: "img-1", ImageURL: "https://x/2.jpg", Cost: 0.0004},
		},
	}

	out, err := ToBifrostImageGenerationResponse(resp)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.Usage == nil || out.Usage.Cost == nil {
		t.Fatalf("expected provider-reported cost, got Usage=%+v", out.Usage)
	}
	if out.Usage.Cost.TotalCost != 0.001 {
		t.Fatalf("total cost = %v, want 0.001", out.Usage.Cost.TotalCost)
	}
}

// With no cost reported, Usage stays nil so datasheet pricing applies.
func TestToBifrostImageGenerationResponse_NoCost(t *testing.T) {
	resp := &RunwareResponse{Data: []RunwareResult{{TaskUUID: "img-2", ImageURL: "https://x/1.jpg"}}}
	out, err := ToBifrostImageGenerationResponse(resp)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.Usage != nil {
		t.Fatalf("expected nil Usage when cost absent, got %+v", out.Usage)
	}
}
