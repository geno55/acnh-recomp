// NG word checker (nn::ngc::ProfanityFilter). The SDK's implementation reads its word lists from the system data
// archive NgWord2 (0100000000000823), which isn't part of a game dump: Initialize then aborts while mounting it.
// Offline nothing needs filtering, so the filter here knows no words: every check passes and no text is masked.
#include "../hle.h"

// nn::Result Initialize(void *work, size_t size, bool check_desired_language)
HLE_FUNC("_ZN2nn3ngc15ProfanityFilter10InitializeEPvmb", ngc_initialize) {
    LOG("[ngc] ProfanityFilter::Initialize (no word lists: nothing is filtered)\n");
    c->x[0] = 0;
}

// void SetMaskMode(MaskMode)
HLE_FUNC("_ZN2nn3ngc15ProfanityFilter11SetMaskModeENS1_8MaskModeE", ngc_set_mask_mode) { (void)c; }

// nn::Result CheckProfanityWords(u32 *out_results, u32 pattern_list, const char16_t **words, size_t count):
// one bit set per pattern a word matches - none
static void check_words(Cpu *c) {
    uint32_t *out = (uint32_t *)(uintptr_t)c->x[1];
    uint64_t n = c->x[4];
    for (uint64_t i = 0; out && i < n; i++) out[i] = 0;
    c->x[0] = 0;
}
HLE_FUNC("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKDsm", ngc_check_u16) { check_words(c); }
HLE_FUNC("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKcm", ngc_check_u8) { check_words(c); }

// nn::Result MaskProfanityWordsInText(int *out_count, char16_t *text, u32 pattern_list): the text is left as is
static void mask_text(Cpu *c) {
    int32_t *count = (int32_t *)(uintptr_t)c->x[1];
    if (count) *count = 0;
    c->x[0] = 0;
}
HLE_FUNC("_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPDsj", ngc_mask_u16) { mask_text(c); }
HLE_FUNC("_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPcj", ngc_mask_u8) { mask_text(c); }
