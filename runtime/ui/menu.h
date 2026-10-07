// In-game overlay menu (Dear ImGui). Open with F1 / Esc, or Minus+Plus (Back+Start) on a controller.
#pragma once
#include <stdbool.h>

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef union SDL_Event SDL_Event;

// Main (UI) thread: returns true if the event was consumed by the menu (the game must not see it).
bool menu_handle_event(const SDL_Event *e);
bool menu_is_open(void);
// Main thread: apply window requests (fullscreen) made from the menu.
void menu_apply_window_requests(void *sdl_window);

#ifdef __OBJC__
// Render thread: draw the overlay into the drawable after the game image (no-op while closed).
void menu_render(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> target);
#endif

#ifdef __cplusplus
}
#endif
