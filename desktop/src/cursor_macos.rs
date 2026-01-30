use core_graphics::base::CGError;
use core_graphics::geometry::{CGPoint, CGSize};
use std::ffi::{c_char, c_void};
use std::sync::OnceLock;

type CGSConnectionRef = *mut c_void;
type CGImageRef = *mut c_void;

type CGSDefaultConnectionForThreadFn = unsafe extern "C" fn() -> CGSConnectionRef;
type CGSGetCurrentCursorInfoFn = unsafe extern "C" fn(
    connection: CGSConnectionRef,
    cursor_type: *mut i32,
    cursor_image: *mut CGImageRef,
    hot_spot: *mut CGPoint,
    size: *mut CGSize,
) -> CGError;

struct CgsFns {
    default_connection_for_thread: CGSDefaultConnectionForThreadFn,
    get_current_cursor_info: CGSGetCurrentCursorInfoFn,
}

static CGS_FNS: OnceLock<Option<CgsFns>> = OnceLock::new();

const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;

extern "C" {
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

fn cgs_fns() -> Option<&'static CgsFns> {
    CGS_FNS
        .get_or_init(|| unsafe {
            let default_connection = dlsym(
                RTLD_DEFAULT,
                b"CGSDefaultConnectionForThread\0".as_ptr() as *const c_char,
            );
            if default_connection.is_null() {
                return None;
            }

            let get_cursor_info = dlsym(
                RTLD_DEFAULT,
                b"CGSGetCurrentCursorInfo\0".as_ptr() as *const c_char,
            );
            if get_cursor_info.is_null() {
                return None;
            }

            Some(CgsFns {
                default_connection_for_thread: std::mem::transmute(default_connection),
                get_current_cursor_info: std::mem::transmute(get_cursor_info),
            })
        })
        .as_ref()
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGImageGetWidth(image: CGImageRef) -> usize;
    fn CGImageGetHeight(image: CGImageRef) -> usize;
    fn CGImageGetBitsPerComponent(image: CGImageRef) -> usize;
    fn CGImageGetBitsPerPixel(image: CGImageRef) -> usize;
    fn CGImageGetBytesPerRow(image: CGImageRef) -> usize;
    fn CGImageGetDataProvider(image: CGImageRef) -> *mut c_void;
    fn CGDataProviderCopyData(provider: *mut c_void) -> *mut c_void;
    fn CFDataGetLength(data: *mut c_void) -> isize;
    fn CFDataGetBytePtr(data: *mut c_void) -> *const u8;
    fn CFRelease(cf: *mut c_void);
}

#[derive(Clone, Debug)]
pub struct SystemCursor {
    pub width: u16,
    pub height: u16,
    pub hotspot_x: u16,
    pub hotspot_y: u16,
    pub pixels: Vec<u8>,
    pub mask: Vec<u8>,
}

pub fn capture_cursor() -> Option<SystemCursor> {
    unsafe {
        let cgs = match cgs_fns() {
            Some(cgs) => cgs,
            None => return Some(fallback_cursor()),
        };
        let connection = (cgs.default_connection_for_thread)();
        if connection.is_null() {
            return None;
        }

        let mut cursor_type: i32 = 0;
        let mut cursor_image: CGImageRef = std::ptr::null_mut();
        let mut hot_spot = CGPoint { x: 0.0, y: 0.0 };
        let mut size = CGSize {
            width: 0.0,
            height: 0.0,
        };

        let result = (cgs.get_current_cursor_info)(
            connection,
            &mut cursor_type,
            &mut cursor_image,
            &mut hot_spot,
            &mut size,
        );

        if result != 0 || cursor_image.is_null() {
            return None;
        }

        let width = CGImageGetWidth(cursor_image);
        let height = CGImageGetHeight(cursor_image);
        if width == 0 || height == 0 || width > 256 || height > 256 {
            return None;
        }

        let (pixels, mask) = extract_cursor_pixels(cursor_image, width, height)?;

        Some(SystemCursor {
            width: width as u16,
            height: height as u16,
            hotspot_x: hot_spot.x.round().max(0.0).min(width as f64) as u16,
            hotspot_y: hot_spot.y.round().max(0.0).min(height as f64) as u16,
            pixels,
            mask,
        })
    }
}

fn fallback_cursor() -> SystemCursor {
    let width = 16usize;
    let height = 16usize;
    let mut pixels = Vec::with_capacity(width * height * 4);
    let mask_stride = (width + 7) / 8;
    let mut mask = vec![0u8; mask_stride * height];

    for y in 0..height {
        for x in 0..width {
            let mut a = 0u8;
            let mut r = 0u8;
            let mut g = 0u8;
            let mut b = 0u8;

            if x <= y && x < 8 && y < 12 {
                a = 255;
                r = 255;
                g = 255;
                b = 255;
                if x == 0 || x == y || y == 11 {
                    r = 0;
                    g = 0;
                    b = 0;
                }
            }

            pixels.push(b);
            pixels.push(g);
            pixels.push(r);
            pixels.push(a);

            if a > 0 {
                let mask_idx = y * mask_stride + x / 8;
                mask[mask_idx] |= 1 << (7 - (x % 8));
            }
        }
    }

    SystemCursor {
        width: width as u16,
        height: height as u16,
        hotspot_x: 0,
        hotspot_y: 0,
        pixels,
        mask,
    }
}

unsafe fn extract_cursor_pixels(
    image: CGImageRef,
    width: usize,
    height: usize,
) -> Option<(Vec<u8>, Vec<u8>)> {
    let provider = CGImageGetDataProvider(image);
    if provider.is_null() {
        return None;
    }

    let data = CGDataProviderCopyData(provider);
    if data.is_null() {
        return None;
    }

    let len = CFDataGetLength(data) as usize;
    let ptr = CFDataGetBytePtr(data);
    if ptr.is_null() || len == 0 {
        CFRelease(data);
        return None;
    }

    let bytes_per_row = CGImageGetBytesPerRow(image);
    let bits_per_pixel = CGImageGetBitsPerPixel(image);
    let bytes_per_pixel = bits_per_pixel / 8;

    if bytes_per_pixel < 4 || bytes_per_row < width * bytes_per_pixel {
        CFRelease(data);
        return None;
    }

    let mut pixels = Vec::with_capacity(width * height * 4);
    let mask_stride = (width + 7) / 8;
    let mut mask = vec![0u8; mask_stride * height];

    for y in 0..height {
        for x in 0..width {
            let idx = y * bytes_per_row + x * bytes_per_pixel;
            if idx + 3 >= len {
                CFRelease(data);
                return None;
            }
            let r = *ptr.add(idx);
            let g = *ptr.add(idx + 1);
            let b = *ptr.add(idx + 2);
            let a = *ptr.add(idx + 3);

            // Convert RGBA to BGRA for VNC
            pixels.push(b);
            pixels.push(g);
            pixels.push(r);
            pixels.push(a);

            // Set mask bit (alpha > 128 = visible)
            if a > 128 {
                let mask_idx = y * mask_stride + x / 8;
                mask[mask_idx] |= 1 << (7 - (x % 8));
            }
        }
    }

    CFRelease(data);
    Some((pixels, mask))
}

pub fn cursor_changed(last: &Option<SystemCursor>, current: &SystemCursor) -> bool {
    match last {
        None => true,
        Some(prev) => {
            prev.width != current.width
                || prev.height != current.height
                || prev.hotspot_x != current.hotspot_x
                || prev.hotspot_y != current.hotspot_y
                || prev.pixels != current.pixels
        }
    }
}
