#include <Carbon/Carbon.h>

void ax_init() {
  const void *keys[] = { kAXTrustedCheckOptionPrompt };
  const void *values[] = { kCFBooleanTrue };

  CFDictionaryRef options;
  options = CFDictionaryCreate(kCFAllocatorDefault,
                               keys,
                               values,
                               sizeof(keys) / sizeof(*keys),
                               &kCFCopyStringDictionaryKeyCallBacks,
                               &kCFTypeDictionaryValueCallBacks     );

  bool trusted = AXIsProcessTrustedWithOptions(options);
  CFRelease(options);
  if (!trusted) exit(1);
}

void ax_perform_click(AXUIElementRef element) {
  if (!element) return;
  AXUIElementPerformAction(element, kAXCancelAction);
  usleep(150000);
  AXUIElementPerformAction(element, kAXPressAction);
}

CFStringRef ax_get_title(AXUIElementRef element) {
  CFTypeRef title = NULL;
  AXError error = AXUIElementCopyAttributeValue(element,
                                                kAXTitleAttribute,
                                                &title            );

  if (error != kAXErrorSuccess) return NULL;
  return title;
}

static CFArrayRef ax_menubar_children(AXUIElementRef app) {
  AXUIElementRef menubars_ref = NULL;
  CFArrayRef children_ref = NULL;

  AXError error = AXUIElementCopyAttributeValue(app,
                                                kAXMenuBarAttribute,
                                                (CFTypeRef*)&menubars_ref);
  if (error != kAXErrorSuccess) return NULL;
  error = AXUIElementCopyAttributeValue(menubars_ref,
                                        kAXVisibleChildrenAttribute,
                                        (CFTypeRef*)&children_ref   );
  CFRelease(menubars_ref);
  if (error != kAXErrorSuccess) return NULL;
  return children_ref;
}

void ax_select_menu_option(AXUIElementRef app, int id) {
  CFArrayRef children_ref = ax_menubar_children(app);
  if (!children_ref) return;
  uint32_t count = CFArrayGetCount(children_ref);
  if (id < count) {
    AXUIElementRef item = CFArrayGetValueAtIndex(children_ref, id);
    ax_perform_click(item);
  }
  CFRelease(children_ref);
}

void ax_print_menu_options(AXUIElementRef app) {
  CFArrayRef children_ref = ax_menubar_children(app);
  if (!children_ref) return;
  uint32_t count = CFArrayGetCount(children_ref);

  for (int i = 1; i < count; i++) {
    AXUIElementRef item = CFArrayGetValueAtIndex(children_ref, i);
    CFTypeRef title = ax_get_title(item);

    if (title) {
      uint32_t buffer_len = 2*CFStringGetLength(title);
      char buffer[2*CFStringGetLength(title)];
      CFStringGetCString(title, buffer, buffer_len, kCFStringEncodingUTF8);
      printf("%s\n", buffer);
      CFRelease(title);
    }
  }
  CFRelease(children_ref);
}

// The AXMenu holding the entries of top-level menu `id`
static AXUIElementRef ax_menu_of(AXUIElementRef app, int id) {
  CFArrayRef children_ref = ax_menubar_children(app);
  if (!children_ref) return NULL;
  uint32_t count = CFArrayGetCount(children_ref);
  AXUIElementRef menu = NULL;
  if (id < count) {
    AXUIElementRef item = CFArrayGetValueAtIndex(children_ref, id);
    CFArrayRef sub = NULL;
    AXError error = AXUIElementCopyAttributeValue(item,
                                                  kAXChildrenAttribute,
                                                  (CFTypeRef*)&sub     );
    if (error == kAXErrorSuccess && CFArrayGetCount(sub) > 0) {
      menu = (AXUIElementRef)CFArrayGetValueAtIndex(sub, 0);
      CFRetain(menu);
    }
    if (sub) CFRelease(sub);
  }
  CFRelease(children_ref);
  return menu;
}

// Print "index<TAB>title<TAB>shortcut" for each pressable entry of menu `id`
void ax_print_menu_items(AXUIElementRef app, int id) {
  AXUIElementRef menu = ax_menu_of(app, id);
  if (!menu) return;
  CFArrayRef items = NULL;
  AXError error = AXUIElementCopyAttributeValue(menu,
                                                kAXChildrenAttribute,
                                                (CFTypeRef*)&items   );
  if (error == kAXErrorSuccess) {
    uint32_t count = CFArrayGetCount(items);
    for (int i = 0; i < count; i++) {
      AXUIElementRef entry = CFArrayGetValueAtIndex(items, i);
      CFTypeRef title = ax_get_title(entry);
      if (!title || CFStringGetLength(title) == 0) {
        if (title) CFRelease(title);
        continue; // separator
      }
      CFTypeRef enabled_ref = NULL;
      AXUIElementCopyAttributeValue(entry, kAXEnabledAttribute, &enabled_ref);
      bool enabled = enabled_ref == kCFBooleanTrue;
      if (enabled_ref) CFRelease(enabled_ref);
      if (!enabled) { CFRelease(title); continue; }

      char buffer[512];
      CFStringGetCString(title, buffer, sizeof(buffer), kCFStringEncodingUTF8);
      CFRelease(title);

      char shortcut[32] = "";
      CFTypeRef cmd_ref = NULL;
      AXUIElementCopyAttributeValue(entry, CFSTR("AXMenuItemCmdChar"), &cmd_ref);
      if (cmd_ref && CFGetTypeID(cmd_ref) == CFStringGetTypeID()
          && CFStringGetLength((CFStringRef)cmd_ref) > 0) {
        long mods = 0;
        CFTypeRef mod_ref = NULL;
        AXUIElementCopyAttributeValue(entry, CFSTR("AXMenuItemCmdModifiers"), &mod_ref);
        if (mod_ref) {
          CFNumberGetValue((CFNumberRef)mod_ref, kCFNumberLongType, &mods);
          CFRelease(mod_ref);
        }
        char ch[16];
        CFStringGetCString((CFStringRef)cmd_ref, ch, sizeof(ch), kCFStringEncodingUTF8);
        // bit0 shift, bit1 option, bit2 control, bit3 = no command key
        snprintf(shortcut, sizeof(shortcut), "%s%s%s%s%s",
                 (mods & 4) ? "\xe2\x8c\x83" : "",   // ⌃
                 (mods & 2) ? "\xe2\x8c\xa5" : "",   // ⌥
                 (mods & 1) ? "\xe2\x87\xa7" : "",   // ⇧
                 (mods & 8) ? "" : "\xe2\x8c\x98",   // ⌘
                 ch);
      }
      if (cmd_ref) CFRelease(cmd_ref);
      printf("%d\t%s\t%s\n", i, buffer, shortcut);
    }
    CFRelease(items);
  }
  CFRelease(menu);
}

// Press entry `entry_id` of menu `id` directly (no native dropdown)
void ax_press_menu_item(AXUIElementRef app, int id, int entry_id) {
  AXUIElementRef menu = ax_menu_of(app, id);
  if (!menu) return;
  CFArrayRef items = NULL;
  AXError error = AXUIElementCopyAttributeValue(menu,
                                                kAXChildrenAttribute,
                                                (CFTypeRef*)&items   );
  if (error == kAXErrorSuccess) {
    uint32_t count = CFArrayGetCount(items);
    if (entry_id < count) {
      AXUIElementRef entry = CFArrayGetValueAtIndex(items, entry_id);
      AXUIElementPerformAction(entry, kAXPressAction);
    }
    CFRelease(items);
  }
  CFRelease(menu);
}

AXUIElementRef ax_get_extra_menu_item(char* alias) {
  pid_t pid = 0;
  CGRect bounds = CGRectNull;
  CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll,
                                                      kCGNullWindowID        );
  char owner_buffer[256];
  char name_buffer[256];
  char buffer[512];
  int window_count = CFArrayGetCount(window_list);
  for (int i = 0; i < window_count; ++i) {
    CFDictionaryRef dictionary = CFArrayGetValueAtIndex(window_list, i);
    if (!dictionary) continue;

    CFStringRef owner_ref = CFDictionaryGetValue(dictionary,
                                                 kCGWindowOwnerName);

    CFNumberRef owner_pid_ref = CFDictionaryGetValue(dictionary,
                                                     kCGWindowOwnerPID);

    CFStringRef name_ref = CFDictionaryGetValue(dictionary, kCGWindowName);
    CFNumberRef layer_ref = CFDictionaryGetValue(dictionary, kCGWindowLayer);
    CFDictionaryRef bounds_ref = CFDictionaryGetValue(dictionary,
                                                      kCGWindowBounds);

    if (!name_ref || !owner_ref || !owner_pid_ref || !layer_ref || !bounds_ref)
      continue;

    long long int layer = 0;
    CFNumberGetValue(layer_ref, CFNumberGetType(layer_ref), &layer);
    uint64_t owner_pid = 0;
    CFNumberGetValue(owner_pid_ref,
                     CFNumberGetType(owner_pid_ref),
                     &owner_pid                     );

    if (layer != 0x19) continue;
    bounds = CGRectNull;
    if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &bounds)) continue;
    CFStringGetCString(owner_ref,
                       owner_buffer,
                       sizeof(owner_buffer),
                       kCFStringEncodingUTF8);

    CFStringGetCString(name_ref,
                       name_buffer,
                       sizeof(name_buffer),
                       kCFStringEncodingUTF8);
    snprintf(buffer, sizeof(buffer), "%s,%s", owner_buffer, name_buffer);

    if (strcmp(buffer, alias) == 0) {
      pid = owner_pid;
      break;
    }
  }
  CFRelease(window_list);
  if (!pid) return NULL;

  AXUIElementRef app = AXUIElementCreateApplication(pid);
  if (!app) return NULL;
  AXUIElementRef result = NULL;
  CFTypeRef extras = NULL;
  CFArrayRef children_ref = NULL;
  AXError error = AXUIElementCopyAttributeValue(app,
                                                kAXExtrasMenuBarAttribute,
                                                &extras                   );
  if (error == kAXErrorSuccess) {
    error = AXUIElementCopyAttributeValue(extras,
                                          kAXVisibleChildrenAttribute,
                                          (CFTypeRef*)&children_ref   );

    if (error == kAXErrorSuccess) {
      uint32_t count = CFArrayGetCount(children_ref);
      for (uint32_t i = 0; i < count; i++) {
        AXUIElementRef item = CFArrayGetValueAtIndex(children_ref, i);
        CFTypeRef position_ref = NULL;
        CFTypeRef size_ref = NULL;
        AXUIElementCopyAttributeValue(item, kAXPositionAttribute,
                                            &position_ref        );
        AXUIElementCopyAttributeValue(item, kAXSizeAttribute,
                                            &size_ref        );
        if (!position_ref || !size_ref) continue;

        CGPoint position = CGPointZero;
        AXValueGetValue(position_ref, kAXValueCGPointType, &position);
        CGSize size = CGSizeZero;
        AXValueGetValue(size_ref, kAXValueCGSizeType, &size);
        CFRelease(position_ref);
        CFRelease(size_ref);
        if (error == kAXErrorSuccess
            && fabs(position.x - bounds.origin.x) <= 10) {
          result = item;
          break;
        }
      }
    }
  }

  CFRelease(app);
  return result;
}

extern int SLSMainConnectionID();
extern void SLSSetMenuBarVisibilityOverrideOnDisplay(int cid, int did, bool enabled);
extern void SLSSetMenuBarInsetAndAlpha(int cid, double u1, double u2, float alpha);
void ax_select_menu_extra(char* alias) {
  AXUIElementRef item = ax_get_extra_menu_item(alias);
  if (!item) return;
  SLSSetMenuBarInsetAndAlpha(SLSMainConnectionID(), 0, 1, 0.0);
  SLSSetMenuBarVisibilityOverrideOnDisplay(SLSMainConnectionID(), 0, true);
  SLSSetMenuBarInsetAndAlpha(SLSMainConnectionID(), 0, 1, 0.0);
  ax_perform_click(item);
  SLSSetMenuBarVisibilityOverrideOnDisplay(SLSMainConnectionID(), 0, false);
  SLSSetMenuBarInsetAndAlpha(SLSMainConnectionID(), 0, 1, 1.0);
  CFRelease(item);
}

extern void _SLPSGetFrontProcess(ProcessSerialNumber* psn);
extern void SLSGetConnectionIDForPSN(int cid, ProcessSerialNumber* psn, int* cid_out);
extern void SLSConnectionGetPID(int cid, pid_t* pid_out);
AXUIElementRef ax_get_front_app() {
  ProcessSerialNumber psn;
  _SLPSGetFrontProcess(&psn);
  int target_cid;
  SLSGetConnectionIDForPSN(SLSMainConnectionID(), &psn, &target_cid);

  pid_t pid;
  SLSConnectionGetPID(target_cid, &pid);
  return AXUIElementCreateApplication(pid);
}

int main (int argc, char **argv) {
  if (argc == 1) {
    printf("Usage: %s [-l | -s id/alias | -i menu_id | -p menu_id entry_id]\n", argv[0]);
    exit(0);
  }
  ax_init();
  if (strcmp(argv[1], "-l") == 0) {
    AXUIElementRef app = ax_get_front_app();
    if (!app) return 1;
    ax_print_menu_options(app);
    CFRelease(app);
  } else if (argc == 3 && strcmp(argv[1], "-i") == 0) {
    int id = 0;
    if (sscanf(argv[2], "%d", &id) == 1) {
      AXUIElementRef app = ax_get_front_app();
      if (!app) return 1;
      ax_print_menu_items(app, id);
      CFRelease(app);
    }
  } else if (argc == 4 && strcmp(argv[1], "-p") == 0) {
    int id = 0, entry = 0;
    if (sscanf(argv[2], "%d", &id) == 1 && sscanf(argv[3], "%d", &entry) == 1) {
      AXUIElementRef app = ax_get_front_app();
      if (!app) return 1;
      ax_press_menu_item(app, id, entry);
      CFRelease(app);
    }
  } else if (argc == 3 && strcmp(argv[1], "-s") == 0) {
    int id = 0;
    if (sscanf(argv[2], "%d", &id) == 1) {
      AXUIElementRef app = ax_get_front_app();
      if (!app) return 1;
      ax_select_menu_option(app, id);
      CFRelease(app);
    } else ax_select_menu_extra(argv[2]);
  }
  return 0;
}
