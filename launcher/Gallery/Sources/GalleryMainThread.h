//
//  GalleryMainThread.h
//  CartoucheGallery
//
//  Where the gallery's main thread is, read from another thread while the
//  main thread is held: the watch of the UI tests looks at it
//  (GalleryWatch, GalleryTesting.swift).
//

#ifndef GalleryMainThread_h
#define GalleryMainThread_h

#include <stdint.h>

/// On the main thread, before GalleryMainThreadStack: which thread it is,
/// and where its stack lies.
void GalleryMainThreadNote(void);

/// From another thread: where the main thread is, as addresses in the code,
/// the innermost first, then where each caller goes on in turn, at most
/// CAPACITY of them in FRAMES. The main thread stops for as long as its
/// registers and its stack are read, which takes no lock and allocates
/// nothing, then goes on. Returns how many addresses it read: none before
/// GalleryMainThreadNote.
int GalleryMainThreadStack(uintptr_t *frames, int capacity);

/// The path of the image, the app or a library, whose code ADDRESS is in;
/// NULL for none. From one thread at a time: it looks in a table of the
/// images loaded, sorted by address, which it takes again as images load.
const char *GalleryImagePath(uintptr_t address);

#endif /* GalleryMainThread_h */
