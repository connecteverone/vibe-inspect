use block::{Block, ConcreteBlock};
use libc::c_void;
use super::ffi::*;
use super::config::Config;
use super::display::Display;
use super::frame::Frame;
use std::ptr;

extern "C" fn dispatch_noop(_: *mut c_void) {}

pub struct Capturer {
    stream: CGDisplayStreamRef,
    queue: DispatchQueue,

    width: usize,
    height: usize,
    format: PixelFormat,
    display: Display
}

impl Capturer {
    pub fn new<F: Fn(Frame) + 'static>(
        display: Display,
        width: usize,
        height: usize,
        format: PixelFormat,
        config: Config,
        handler: F
    ) -> Result<Capturer, CGError> {
        let handler: FrameAvailableHandler =
            ConcreteBlock::new(move |status, _, surface: IOSurfaceRef, _| {
                use self::CGDisplayStreamFrameStatus::*;
                if status == FrameComplete && !surface.is_null() {
                    if let Some(frame) = unsafe { Frame::new(surface) } {
                        handler(frame);
                    }
                }
            }).copy();

        let queue = unsafe {
            dispatch_queue_create(
                b"quadrupleslap.scrap\0".as_ptr() as *const i8,
                ptr::null_mut()
            )
        };

        let stream = unsafe {
            let config = config.build();
            let stream = CGDisplayStreamCreateWithDispatchQueue(
                display.id(),
                width,
                height,
                format,
                config,
                queue,
                &*handler as *const Block<_, _> as *const c_void
            );
            CFRelease(config);
            stream
        };

        match unsafe { CGDisplayStreamStart(stream) } {
            CGError::Success => Ok(Capturer {
                stream, queue, width, height, format, display
            }),
            x => Err(x)
        }
    }

    pub fn width(&self) -> usize { self.width }
    pub fn height(&self) -> usize { self.height }
    pub fn format(&self) -> PixelFormat { self.format }
    pub fn display(&self) -> Display { self.display }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        unsafe {
            let _ = CGDisplayStreamStop(self.stream);
            dispatch_sync_f(self.queue, ptr::null_mut(), dispatch_noop);
            CFRelease(self.stream);
            dispatch_release(self.queue);
        }
    }
}
