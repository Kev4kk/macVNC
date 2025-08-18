
/*
 *  OSXvnc Copyright (C) 2001 Dan McGuirk <mcguirk@incompleteness.net>.
 *  Original Xvnc code Copyright (C) 1999 AT&T Laboratories Cambridge.  
 *  All Rights Reserved.
 * 
 * Cut in two parts by Johannes Schindelin (2001): libvncserver and OSXvnc.
 * 
 * Completely revamped and adapted to work with contemporary APIs by Christian Beier (2020).
 * 
 * This file implements every system specific function for Mac OS X.
 * 
 *  It includes the keyboard function:
 * 
     void KbdAddEvent(down, keySym, cl)
        rfbBool down;
        rfbKeySym keySym;
        rfbClientPtr cl;
 * 
 *  the mouse function:
 * 
     void PtrAddEvent(buttonMask, x, y, cl)
        int buttonMask;
        int x;
        int y;
        rfbClientPtr cl;
 * 
 */

#include <Carbon/Carbon.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>
#include <CoreGraphics/CGWindow.h>
#include <ApplicationServices/ApplicationServices.h>
#include <rfb/rfb.h>
#include <rfb/keysym.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/pwr_mgt/IOPM.h>
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>

#import "ScreenCapturer.h"

/* The main LibVNCServer screen object */
rfbScreenInfoPtr rfbScreen;
/* Operation modes set by CLI options */
rfbBool viewOnly = FALSE;

/* Two framebuffers. */
void *frameBufferOne;
void *frameBufferTwo;

/* Pointer to the current backbuffer. */
void *backBuffer;

/* Window capture settings */
static uint32_t targetWindowID = 0;
static CGRect captureFrame;
static int captureWidth = 0;
static int captureHeight = 0;
static pid_t targetPid = 0;

/* The server's private event source */
CGEventSourceRef eventSource;

/* Screen (un)dimming machinery */
rfbBool preventDimming = FALSE;
rfbBool preventSleep   = TRUE;
static pthread_mutex_t  dimming_mutex;
static unsigned long    dim_time;
static unsigned long    sleep_time;
static mach_port_t      master_dev_port;
static io_connect_t     power_mgt;
static rfbBool initialized            = FALSE;
static rfbBool dim_time_saved         = FALSE;
static rfbBool sleep_time_saved       = FALSE;

/* a dictionary mapping characters to keycodes */
CFMutableDictionaryRef charKeyMap;

/* a dictionary mapping characters obtained by Shift to keycodes */
CFMutableDictionaryRef charShiftKeyMap;

/* a dictionary mapping characters obtained by Alt-Gr to keycodes */
CFMutableDictionaryRef charAltGrKeyMap;

/* a dictionary mapping characters obtained by Shift+Alt-Gr to keycodes */
CFMutableDictionaryRef charShiftAltGrKeyMap;

/* a table mapping special keys to keycodes. static as these are layout-independent */
static int specialKeyMap[] = {
    /* "Special" keys */
    XK_space,             49,      /* Space */
    XK_Return,            36,      /* Return */
    XK_Delete,           117,      /* Delete */
    XK_Tab,               48,      /* Tab */
    XK_Escape,            53,      /* Esc */
    XK_Caps_Lock,         57,      /* Caps Lock */
    XK_Num_Lock,          71,      /* Num Lock */
    XK_Scroll_Lock,      107,      /* Scroll Lock */
    XK_Pause,            113,      /* Pause */
    XK_BackSpace,         51,      /* Backspace */
    XK_Insert,           114,      /* Insert */

    /* Cursor movement */
    XK_Up,               126,      /* Cursor Up */
    XK_Down,             125,      /* Cursor Down */
    XK_Left,             123,      /* Cursor Left */
    XK_Right,            124,      /* Cursor Right */
    XK_Page_Up,          116,      /* Page Up */
    XK_Page_Down,        121,      /* Page Down */
    XK_Home,             115,      /* Home */
    XK_End,              119,      /* End */

    /* Numeric keypad */
    XK_KP_0,              82,      /* KP 0 */
    XK_KP_1,              83,      /* KP 1 */
    XK_KP_2,              84,      /* KP 2 */
    XK_KP_3,              85,      /* KP 3 */
    XK_KP_4,              86,      /* KP 4 */
    XK_KP_5,              87,      /* KP 5 */
    XK_KP_6,              88,      /* KP 6 */
    XK_KP_7,              89,      /* KP 7 */
    XK_KP_8,              91,      /* KP 8 */
    XK_KP_9,              92,      /* KP 9 */
    XK_KP_Enter,          76,      /* KP Enter */
    XK_KP_Decimal,        65,      /* KP . */
    XK_KP_Add,            69,      /* KP + */
    XK_KP_Subtract,       78,      /* KP - */
    XK_KP_Multiply,       67,      /* KP * */
    XK_KP_Divide,         75,      /* KP / */

    /* Function keys */
    XK_F1,               122,      /* F1 */
    XK_F2,               120,      /* F2 */
    XK_F3,                99,      /* F3 */
    XK_F4,               118,      /* F4 */
    XK_F5,                96,      /* F5 */
    XK_F6,                97,      /* F6 */
    XK_F7,                98,      /* F7 */
    XK_F8,               100,      /* F8 */
    XK_F9,               101,      /* F9 */
    XK_F10,              109,      /* F10 */
    XK_F11,              103,      /* F11 */
    XK_F12,              111,      /* F12 */

    /* Modifier keys */
    XK_Shift_L,           56,      /* Shift Left */
    XK_Shift_R,           56,      /* Shift Right */
    XK_Control_L,         59,      /* Ctrl Left */
    XK_Control_R,         59,      /* Ctrl Right */
    XK_Meta_L,            58,      /* Logo Left (-> Option) */
    XK_Meta_R,            58,      /* Logo Right (-> Option) */
    XK_Alt_L,             55,      /* Alt Left (-> Command) */
    XK_Alt_R,             55,      /* Alt Right (-> Command) */
    XK_ISO_Level3_Shift,  61,      /* Alt-Gr (-> Option Right) */
    0x1008FF2B,           63,      /* Fn */

    /* Weirdness I can't figure out */
#if 0
    XK_3270_PrintScreen,     105,     /* PrintScrn */
    ???  94,          50,      /* International */
    XK_Menu,              50,      /* Menu (-> International) */
#endif
};

/* Global shifting modifier states */
rfbBool isShiftDown;
rfbBool isAltGrDown;


static int
saveDimSettings(void)
{
    if (IOPMGetAggressiveness(power_mgt, 
                              kPMMinutesToDim, 
                              &dim_time) != kIOReturnSuccess)
        return -1;

    dim_time_saved = TRUE;
    return 0;
}

static int
restoreDimSettings(void)
{
    if (!dim_time_saved)
        return -1;

    if (IOPMSetAggressiveness(power_mgt, 
                              kPMMinutesToDim, 
                              dim_time) != kIOReturnSuccess)
        return -1;

    dim_time_saved = FALSE;
    dim_time = 0;
    return 0;
}

static int
saveSleepSettings(void)
{
    if (IOPMGetAggressiveness(power_mgt, 
                              kPMMinutesToSleep, 
                              &sleep_time) != kIOReturnSuccess)
        return -1;

    sleep_time_saved = TRUE;
    return 0;
}

static int
restoreSleepSettings(void)
{
    if (!sleep_time_saved)
        return -1;

    if (IOPMSetAggressiveness(power_mgt, 
                              kPMMinutesToSleep, 
                              sleep_time) != kIOReturnSuccess)
        return -1;

    sleep_time_saved = FALSE;
    sleep_time = 0;
    return 0;
}


int
dimmingInit(void)
{
    pthread_mutex_init(&dimming_mutex, NULL);

#if __MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_VERSION_12_0
    if (IOMainPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#else
    if (IOMasterPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#endif
        return -1;

    if (!(power_mgt = IOPMFindPowerManagement(master_dev_port)))
        return -1;

    if (preventDimming) {
        if (saveDimSettings() < 0)
            return -1;
        if (IOPMSetAggressiveness(power_mgt, 
                                  kPMMinutesToDim, 0) != kIOReturnSuccess)
            return -1;
    }

    if (preventSleep) {
        if (saveSleepSettings() < 0)
            return -1;
        if (IOPMSetAggressiveness(power_mgt, 
                                  kPMMinutesToSleep, 0) != kIOReturnSuccess)
            return -1;
    }

    initialized = TRUE;
    return 0;
}


int
undim(void)
{
    int result = -1;

    pthread_mutex_lock(&dimming_mutex);
    
    if (!initialized)
        goto DONE;

    if (!preventDimming) {
        if (saveDimSettings() < 0)
            goto DONE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToDim, 0) != kIOReturnSuccess)
            goto DONE;
        if (restoreDimSettings() < 0)
            goto DONE;
    }
    
    if (!preventSleep) {
        if (saveSleepSettings() < 0)
            goto DONE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToSleep, 0) != kIOReturnSuccess)
            goto DONE;
        if (restoreSleepSettings() < 0)
            goto DONE;
    }

    result = 0;

 DONE:
    pthread_mutex_unlock(&dimming_mutex);
    return result;
}


int
dimmingShutdown(void)
{
    int result = -1;

    if (!initialized)
        goto DONE;

    pthread_mutex_lock(&dimming_mutex);
    if (dim_time_saved)
        if (restoreDimSettings() < 0)
            goto DONE;
    if (sleep_time_saved)
        if (restoreSleepSettings() < 0)
            goto DONE;

    result = 0;

 DONE:
    pthread_mutex_unlock(&dimming_mutex);
    return result;
}

void serverShutdown(rfbClientPtr cl);

/* List all current windows that have titles, printing: windowid\towner - title */
static void listWindows(void)
{
    CFArrayRef infoArray = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!infoArray) {
        fprintf(stderr, "Unable to query window list.\n");
        return;
    }

    CFIndex count = CFArrayGetCount(infoArray);
    for (CFIndex i = 0; i < count; ++i) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(infoArray, i);
        if (!info) continue;

        CFStringRef title = (CFStringRef)CFDictionaryGetValue(info, kCGWindowName);
        if (!title || CFStringGetLength(title) == 0) continue; /* only windows with titles */

        CFNumberRef numRef = (CFNumberRef)CFDictionaryGetValue(info, kCGWindowNumber);
        int windowId = 0;
        if (!numRef || !CFNumberGetValue(numRef, kCFNumberIntType, &windowId)) continue;

        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(info, kCGWindowOwnerName);

        char titleBuf[1024];
        char ownerBuf[256];
        titleBuf[0] = '\0';
        ownerBuf[0] = '\0';
        if (title) CFStringGetCString(title, titleBuf, sizeof(titleBuf), kCFStringEncodingUTF8);
        if (owner) CFStringGetCString(owner, ownerBuf, sizeof(ownerBuf), kCFStringEncodingUTF8);

        printf("%d\t%s - %s\n", windowId, ownerBuf, titleBuf);
    }

    CFRelease(infoArray);
}

/* Get window frame by CGWindowID */
static rfbBool getWindowFrame(uint32_t windowID, CGRect *outFrame)
{
    rfbBool ok = FALSE;
    CFArrayRef infoArray = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
    if (!infoArray)
        return FALSE;
    if (CFArrayGetCount(infoArray) == 0) {
        CFRelease(infoArray);
        return FALSE;
    }
    CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(infoArray, 0);
    if (info) {
        CFDictionaryRef boundsDict = (CFDictionaryRef)CFDictionaryGetValue(info, kCGWindowBounds);
        if (boundsDict && outFrame) {
            CGRect frame;
            if (CGRectMakeWithDictionaryRepresentation(boundsDict, &frame)) {
                *outFrame = frame;
                ok = TRUE;
            }
        }
    }
    CFRelease(infoArray);
    return ok;
}

/*
  Synthesize a keyboard event. This is not called on the main thread due to rfbRunEventLoop(..,..,TRUE), but it works.
  We first look up the incoming keysym in the keymap for special keys (and save state of the shifting modifiers).
  If the incoming keysym does not map to a special key, the char keymaps pertaining to the respective shifting modifier are used
  in order to allow for keyboard combos with other modifiers.
  As a last resort, the incoming keysym is simply used as a Unicode value. This way MacOS does not support any modifiers though.
*/
void
KbdAddEvent(rfbBool down, rfbKeySym keySym, struct _rfbClientRec* cl)
{
    int i;
    CGKeyCode keyCode = -1;
    CGEventRef keyboardEvent;
    int specialKeyFound = 0;

    undim();

    /* Only allow typing (printable ASCII + space/return/tab/backspace) */
    rfbBool isPrintable = (keySym >= 0x20 && keySym <= 0x7E);
    rfbBool isTypingControl = (keySym == XK_space || keySym == XK_Return || keySym == XK_BackSpace || keySym == XK_Tab);
    if (!isPrintable && !isTypingControl)
        return;

    /* look for special key */
    if (!isPrintable) {
        for (i = 0; i < (sizeof(specialKeyMap) / sizeof(int)); i += 2) {
            if (specialKeyMap[i] == keySym) {
                keyCode = specialKeyMap[i+1];
                specialKeyFound = 1;
                break;
            }
        }
    }

    if(specialKeyFound) {
	/* keycode for special key found */
	keyboardEvent = CGEventCreateKeyboardEvent(eventSource, keyCode, down);
	/* save state of shifting modifiers */
	if(keySym == XK_ISO_Level3_Shift)
	    isAltGrDown = down;
	if(keySym == XK_Shift_L || keySym == XK_Shift_R)
	    isShiftDown = down;

    } else {
	/* look for char key */
	size_t keyCodeFromDict;
	CFStringRef charStr = CFStringCreateWithCharacters(kCFAllocatorDefault, (UniChar*)&keySym, 1);
	CFMutableDictionaryRef keyMap = charKeyMap;
	if(isShiftDown && !isAltGrDown)
	    keyMap = charShiftKeyMap;
	if(!isShiftDown && isAltGrDown)
	    keyMap = charAltGrKeyMap;
	if(isShiftDown && isAltGrDown)
	    keyMap = charShiftAltGrKeyMap;

	if (CFDictionaryGetValueIfPresent(keyMap, charStr, (const void **)&keyCodeFromDict)) {
	    /* keycode for ASCII key found */
	    keyboardEvent = CGEventCreateKeyboardEvent(eventSource, keyCodeFromDict, down);
	} else {
	    /* last resort: use the symbol's utf-16 value, does not support modifiers though */
	    keyboardEvent = CGEventCreateKeyboardEvent(eventSource, 0, down);
	    CGEventKeyboardSetUnicodeString(keyboardEvent, 1, (UniChar*)&keySym);
        }

	CFRelease(charStr);
    }

    /* Set the Shift modifier explicitly as MacOS sometimes gets internal state wrong and Shift stuck. */
    CGEventSetFlags(keyboardEvent, CGEventGetFlags(keyboardEvent) & (isShiftDown ? kCGEventFlagMaskShift : ~kCGEventFlagMaskShift));

    CGEventPost(kCGHIDEventTap, keyboardEvent);
    CFRelease(keyboardEvent);
}

/* Synthesize a mouse event. This is not called on the main thread due to rfbRunEventLoop(..,..,TRUE), but it works. */
void
PtrAddEvent(int buttonMask, int x, int y, rfbClientPtr cl)
{
    CGPoint position;
    CGRect displayBounds = captureFrame;
    CGEventRef mouseEvent = NULL;

    undim();

    position.x = x + displayBounds.origin.x;
    position.y = y + displayBounds.origin.y;

    /* map buttons 4 5 6 7 to scroll events as per https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#745pointerevent */
    if(buttonMask & (1 << 3))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 1, 0);
    if(buttonMask & (1 << 4))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, -1, 0);
    if(buttonMask & (1 << 5))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 0, 1);
    if(buttonMask & (1 << 6))
	mouseEvent = CGEventCreateScrollWheelEvent(eventSource, kCGScrollEventUnitLine, 2, 0, -1);

    if (mouseEvent) {
	CGEventPost(kCGSessionEventTap, mouseEvent);
	CFRelease(mouseEvent);
    }
    else {
	/*
	  Use the deprecated CGPostMouseEvent API here as we get a buttonmask plus position which is pretty low-level
	  whereas CGEventCreateMouseEvent is expecting higher-level events. This allows for direct injection of
	  double clicks and drags whereas we would need to synthesize these events for the high-level API.
	 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	CGPostMouseEvent(position, TRUE, 3,
			 (buttonMask & (1 << 0)) ? TRUE : FALSE,
			 (buttonMask & (1 << 2)) ? TRUE : FALSE,
			 (buttonMask & (1 << 1)) ? TRUE : FALSE);
#pragma clang diagnostic pop
    }
}


/*
  Initialises keyboard handling:
  This creates four keymaps mapping UniChars to keycodes for the current keyboard layout with no shifting modifiers, Shift, Alt-Gr and Shift+Alt-Gr applied, respectively.
 */
rfbBool keyboardInit()
{
    size_t i, keyCodeCount=128;
    TISInputSourceRef currentKeyboard = TISCopyCurrentKeyboardInputSource();
    const UCKeyboardLayout *keyboardLayout;

    if(!currentKeyboard) {
	fprintf(stderr, "Could not get current keyboard info\n");
	return FALSE;
    }

    keyboardLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData));

    printf("Found keyboard layout '%s'\n", CFStringGetCStringPtr(TISGetInputSourceProperty(currentKeyboard, kTISPropertyInputSourceID), kCFStringEncodingUTF8));

    charKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);
    charShiftKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);
    charAltGrKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);
    charShiftAltGrKeyMap = CFDictionaryCreateMutable(kCFAllocatorDefault, keyCodeCount, &kCFCopyStringDictionaryKeyCallBacks, NULL);

    if(!charKeyMap || !charShiftKeyMap || !charAltGrKeyMap || !charShiftAltGrKeyMap) {
	fprintf(stderr, "Could not create keymaps\n");
	return FALSE;
    }

    /* Loop through every keycode to find the character it is mapping to. */
    for (i = 0; i < keyCodeCount; ++i) {
	UInt32 deadKeyState = 0;
	UniChar chars[4];
	UniCharCount realLength;
	UInt32 m, modifiers[] = {0, kCGEventFlagMaskShift, kCGEventFlagMaskAlternate, kCGEventFlagMaskShift|kCGEventFlagMaskAlternate};

	/* do this for no modifier, shift and alt-gr applied */
	for(m = 0; m < sizeof(modifiers) / sizeof(modifiers[0]); ++m) {
	    UCKeyTranslate(keyboardLayout,
			   i,
			   kUCKeyActionDisplay,
			   (modifiers[m] >> 16) & 0xff,
			   LMGetKbdType(),
			   kUCKeyTranslateNoDeadKeysBit,
			   &deadKeyState,
			   sizeof(chars) / sizeof(chars[0]),
			   &realLength,
			   chars);

	    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 1);
	    if(string) {
		switch(modifiers[m]) {
		case 0:
		    CFDictionaryAddValue(charKeyMap, string, (const void *)i);
		    break;
		case kCGEventFlagMaskShift:
		    CFDictionaryAddValue(charShiftKeyMap, string, (const void *)i);
		    break;
		case kCGEventFlagMaskAlternate:
		    CFDictionaryAddValue(charAltGrKeyMap, string, (const void *)i);
		    break;
		case kCGEventFlagMaskShift|kCGEventFlagMaskAlternate:
		    CFDictionaryAddValue(charShiftAltGrKeyMap, string, (const void *)i);
		    break;
		}

		CFRelease(string);
	    }
	}
    }

    CFRelease(currentKeyboard);

    return TRUE;
}


rfbBool
ScreenInit(int argc, char**argv)
{
  int bitsPerSample = 8;
  if (targetWindowID == 0) {
      fprintf(stderr, "-windowid <id> is required and must be a valid CGWindowID.\n");
      return FALSE;
  }
 
  /* Initialize capture frame and dimensions for window or display */
  if (targetWindowID != 0) {
      if (!getWindowFrame(targetWindowID, &captureFrame)) {
          fprintf(stderr, "Could not get window %u frame.\n", (unsigned)targetWindowID);
          return FALSE;
      }
  } else {
      /* unreachable: we require -windowid */
      return FALSE;
  }
 
 
   rfbScreen = rfbGetScreen(&argc,argv,
               (int)captureFrame.size.width,
               (int)captureFrame.size.height,
                bitsPerSample,
                3,
                4);
 
   if(!rfbScreen) {
       rfbErr("Could not init rfbScreen.\n");
       return FALSE;
   }
 
   rfbScreen->serverFormat.redShift = bitsPerSample*2;
   rfbScreen->serverFormat.greenShift = bitsPerSample*1;
   rfbScreen->serverFormat.blueShift = 0;
 
   gethostname(rfbScreen->thisHost, 255);
  
  frameBufferOne = malloc((int)captureFrame.size.width * (int)captureFrame.size.height * 4);
  frameBufferTwo = malloc((int)captureFrame.size.width * (int)captureFrame.size.height * 4);

  /* back buffer */
  backBuffer = frameBufferOne;
  /* front buffer */
  rfbScreen->frameBuffer = frameBufferTwo;

  /* we already capture the cursor in the framebuffer */
  rfbScreen->cursor = NULL;

  rfbScreen->ptrAddEvent = PtrAddEvent;
  rfbScreen->kbdAddEvent = KbdAddEvent;
 
  ScreenCapturer *capturer = [[ScreenCapturer alloc] initWithWindowID: (uint32_t)targetWindowID
                                      frameHandler:^(CMSampleBufferRef sampleBuffer) {
          rfbClientIteratorPtr iterator;
          rfbClientPtr cl;

           /*
             Copy new frame to back buffer.
           */
          CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
          if(!pixelBuffer)
              return;

          CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

          memcpy(backBuffer,
                 CVPixelBufferGetBaseAddress(pixelBuffer),
                 (int)captureFrame.size.width * (int)captureFrame.size.height * 4);

          CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

          /* Lock out client reads. */
          iterator=rfbGetClientIterator(rfbScreen);
          while((cl=rfbClientIteratorNext(iterator))) {
              LOCK(cl->sendMutex);
          }
          rfbReleaseClientIterator(iterator);

          /* Swap framebuffers. */
          if (backBuffer == frameBufferOne) {
              backBuffer = frameBufferTwo;
              rfbScreen->frameBuffer = frameBufferOne;
          } else {
              backBuffer = frameBufferOne;
              rfbScreen->frameBuffer = frameBufferTwo;
          }

          /*
            Mark modified rect in new framebuffer.
            ScreenCaptureKit does not have something like CGDisplayStreamUpdateGetRects(),
            so mark the whole framebuffer.
           */
          rfbMarkRectAsModified(rfbScreen, 0, 0, (int)captureFrame.size.width, (int)captureFrame.size.height);

          /* Swapping framebuffers finished, reenable client reads. */
          iterator=rfbGetClientIterator(rfbScreen);
          while((cl=rfbClientIteratorNext(iterator))) {
              UNLOCK(cl->sendMutex);
          }
          rfbReleaseClientIterator(iterator);

      } errorHandler:^(NSError *error) {
          fprintf(stderr, "Error: %s\n", [error.description UTF8String]);
          if(error.code == SCStreamErrorUserDeclined) {
              fprintf(stderr, "Could not get screen contents. Check if the program has been given screen recording permissions in 'System Preferences'->'Security & Privacy'->'Privacy'->'Screen Recording'.\n");
          }
          //TODO handle other errors
          exit(EXIT_FAILURE);
      }];
  [capturer startCapture];

  rfbInitServer(rfbScreen);

  return TRUE;
}


void clientGone(rfbClientPtr cl)
{
    //TODO
}

enum rfbNewClientAction newClient(rfbClientPtr cl)
{
  cl->clientGoneHook = clientGone;
  cl->viewOnly = viewOnly;

  return(RFB_CLIENT_ACCEPT);
}

int main(int argc,char *argv[])
{
  int i;

  for(i=argc-1;i>0;i--)
    if(strcmp(argv[i],"-viewonly")==0) {
      viewOnly=TRUE;
    } else if(strcmp(argv[i],"-windowid")==0) {
        targetWindowID = (uint32_t)strtoul(argv[i+1], NULL, 10);
    } else if(strcmp(argv[i],"-listwindows")==0) {
        listWindows();
        exit(EXIT_SUCCESS);
    } else if(strcmp(argv[i],"-h") == 0 || strcmp(argv[i],"--help") == 0)  {
        fprintf(stderr, "-viewonly              Do not allow any input\n");
        fprintf(stderr, "-windowid <id>         Only export specified window (CGWindowID)\n");
        fprintf(stderr, "-listwindows           Print on-screen windows with titles and their window IDs\n");
        rfbUsage();
        exit(EXIT_SUCCESS);
    }

  if(!viewOnly && !AXIsProcessTrusted()) {
      const void *keys[] = { kAXTrustedCheckOptionPrompt };
      const void *vals[] = { kCFBooleanTrue };
      CFDictionaryRef opts = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
      Boolean trusted = AXIsProcessTrustedWithOptions(opts);
      if (opts) CFRelease(opts);
      if (!trusted) {
          fprintf(stderr, "You have configured the server to post input events, but it does not have the necessary system permission. Please add 'macVNC' (the app bundle) to 'System Settings'->'Privacy & Security'->'Accessibility'. If you rebuilt the app, remove and re-add it.\n");
          exit(1);
      }
  }

  dimmingInit();

  /* Create a private event source for the server. This helps a lot with modifier keys getting stuck on the OS side
     (but does not completely mitigate the issue: For this, we keep track of modifier key state and set it specifically
     for the generated keyboard event in the keyboard event handler). */
  eventSource = CGEventSourceCreate(kCGEventSourceStatePrivate);

  if(!keyboardInit())
      exit(1);

  if(!ScreenInit(argc,argv))
      exit(1);
  rfbScreen->newClientHook = newClient;

  rfbRunEventLoop(rfbScreen,-1,TRUE);

  /*
     The VNC machinery is in the background now and framebuffer updating happens on another thread as well.
  */
  while(1) {
      /* Nothing left to do on the main thread. */
      sleep(1);
  }

  dimmingShutdown();

  return(0); /* never ... */
}

void serverShutdown(rfbClientPtr cl)
{
  rfbScreenCleanup(rfbScreen);
  dimmingShutdown();
  exit(0);
}
