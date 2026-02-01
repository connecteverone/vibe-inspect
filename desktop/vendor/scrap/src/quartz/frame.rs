use super::ffi::*;
use std::{ops, ptr, slice};

pub struct Frame {
    surface: IOSurfaceRef,
    inner: &'static [u8]
}

impl Frame {
    pub unsafe fn new(surface: IOSurfaceRef) -> Option<Frame> {
        if surface.is_null() {
            return None;
        }
        CFRetain(surface);
        IOSurfaceIncrementUseCount(surface);

        IOSurfaceLock(
            surface,
            SURFACE_LOCK_READ_ONLY,
            ptr::null_mut()
        );

        let base = IOSurfaceGetBaseAddress(surface) as *const u8;
        let size = IOSurfaceGetAllocSize(surface);
        if base.is_null() || size == 0 {
            IOSurfaceUnlock(
                surface,
                SURFACE_LOCK_READ_ONLY,
                ptr::null_mut()
            );
            IOSurfaceDecrementUseCount(surface);
            CFRelease(surface);
            return None;
        }
        let inner = slice::from_raw_parts(base, size);

        Some(Frame { surface, inner })
    }
}

impl ops::Deref for Frame {
    type Target = [u8];
    fn deref<'a>(&'a self) -> &'a [u8] {
        self.inner
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        unsafe {
            IOSurfaceUnlock(
                self.surface,
                SURFACE_LOCK_READ_ONLY,
                ptr::null_mut()
            );

            IOSurfaceDecrementUseCount(self.surface);
            CFRelease(self.surface);
        }
    }
}
