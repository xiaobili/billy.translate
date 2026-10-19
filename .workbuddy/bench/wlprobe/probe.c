#include <stdio.h>
#include <wayland-client.h>

static void global(void *data, struct wl_registry *reg, uint32_t name,
                   const char *iface, uint32_t ver) {
  (void)data; (void)reg;
  printf("%-42s v%-3u name=%u\n", iface, ver, name);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t n) {
  (void)d; (void)r; (void)n;
}
static const struct wl_registry_listener rl = { global, global_remove };

int main(void) {
  struct wl_display *d = wl_display_connect(NULL);
  if (!d) { fprintf(stderr, "connect failed\n"); return 1; }
  struct wl_registry *r = wl_display_get_registry(d);
  wl_registry_add_listener(r, &rl, NULL);
  wl_display_roundtrip(d);
  wl_registry_destroy(r);
  wl_display_disconnect(d);
  return 0;
}
