// Save editor tab (filled in once the save layout is mapped -- see notes/save_format.md).
#include "imgui.h"

extern "C" void save_editor_on_open(void) {}

extern "C" void save_editor_draw(float scale) {
    (void)scale;
    ImGui::TextDisabled("Save editor: coming soon.");
}
