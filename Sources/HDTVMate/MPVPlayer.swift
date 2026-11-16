import Cocoa
import OpenGL
import OpenGL.GL3
import QuartzCore
import CMPV

/// libmpv (same ffmpeg core as ffplay) rendering into an in-app OpenGL view.
final class MPVPlayer {
    let mpv: OpaquePointer
    private(set) var view: MPVGLView!
    private let eventQueue = DispatchQueue(label: "hdtvmate.mpv.events")
    var onPlaybackStart: (() -> Void)?
    var onEndFile: (() -> Void)?
    var onLog: ((String) -> Void)?

    init() {
        let h = mpv_create()!
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("profile", "low-latency"),
            ("vd-lavc-threads", "0"),
            ("hwdec", "auto-safe"),
            ("cache", "no"),
            ("sub-create-cc-track", "yes"),
            ("sid", "auto"),
            ("idle", "yes"),
            ("keep-open", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("terminal", "no"),
            ("audio-client-name", "HDTV Mate"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            ("demuxer-lavf-probe-info", "auto"),
            ("demuxer-lavf-analyzeduration", "1.5"),
            ("demuxer-lavf-probesize", "2000000"),
        ]
        for (k, v) in options { mpv_set_option_string(h, k, v) }
        // low-latency sets audio-buffer=0, so any hiccup is an audible underrun.
        mpv_set_option_string(h, "audio-buffer", "0.2")
        #if arch(x86_64)
        // Intel Macs: mpv's default (high-quality) scaling is too heavy at Retina sizes.
        for (k, v) in [("scale", "bilinear"), ("cscale", "bilinear"), ("dscale", "bilinear"),
                       ("dither-depth", "no"), ("correct-downscaling", "no"), ("linear-downscaling", "no"),
                       ("sigmoid-upscaling", "no"), ("deband", "no"), ("hdr-compute-peak", "no")] as [(String, String)] {
            mpv_set_option_string(h, k, v)
        }
        #endif
        mpv_initialize(h)
        mpv_request_log_messages(h, "v")
        mpv = h
        view = MPVGLView(mpv: h)
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            me.eventQueue.async { me.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func drainEvents() {
        while true {
            guard let ev = mpv_wait_event(mpv, 0) else { return }
            let id = ev.pointee.event_id
            if id == MPV_EVENT_NONE || id == MPV_EVENT_SHUTDOWN { return }
            switch id {
            case MPV_EVENT_LOG_MESSAGE:
                if let raw = ev.pointee.data {
                    let m = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let prefix = m.prefix.map { String(cString: $0) } ?? ""
                    let text = m.text.map { String(cString: $0) } ?? ""
                    if text.hasPrefix("Subtitle with unknown duration") { break }
                    emitLog("[mpv/\(prefix)] " + text.trimmingCharacters(in: .newlines))
                }
            case MPV_EVENT_START_FILE:
                emitLog("[mpv] opening stream")
            case MPV_EVENT_FILE_LOADED:
                emitLog("[mpv] stream opened, waiting for first frame")
            case MPV_EVENT_PLAYBACK_RESTART:
                emitLog("[mpv] playback started")
                DispatchQueue.main.async { [weak self] in self?.onPlaybackStart?() }
            case MPV_EVENT_END_FILE:
                if let raw = ev.pointee.data {
                    let e = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    let err = e.error < 0 ? String(cString: mpv_error_string(e.error)) : "none"
                    emitLog("[mpv] stream ended (reason \(e.reason.rawValue), error: \(err))")
                }
                DispatchQueue.main.async { [weak self] in self?.onEndFile?() }
            default:
                break
            }
        }
    }

    private func emitLog(_ line: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(line) }
    }

    func command(_ args: [String]) {
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                _ = mpv_command_async(mpv, 0, p)
            }
        }
        for c in cargs { free(c) }
    }

    func load(_ path: String) { command(["loadfile", path, "replace"]) }
    func stop() { command(["stop"]) }
    /// Non-blocking property change (the main thread also renders, so it must never wait on mpv).
    func set(_ property: String, _ value: String) {
        var cstr: UnsafeMutablePointer<CChar>? = strdup(value)
        withUnsafeMutablePointer(to: &cstr) { p in
            _ = mpv_set_property_async(mpv, 0, property, MPV_FORMAT_STRING, UnsafeMutableRawPointer(p))
        }
        free(cstr)
    }

    func shutdown() {
        view?.destroyRender()
        mpv_terminate_destroy(mpv)
    }
}

/// Video view, backed by a CAOpenGLLayer (the approach IINA uses with libmpv).
/// Frames are drawn from a private serial queue, never the main thread, so a busy
/// SwiftUI window can't stall mpv's playback.
final class MPVGLView: NSView {
    private let mpv: OpaquePointer
    private var videoLayer: MPVLayer? { layer as? MPVLayer }
    var renderStatus: String { videoLayer?.renderStatus ?? "no video layer" }
    var drawCount: Int { videoLayer?.drawCount ?? 0 }

    init(mpv: OpaquePointer) {
        self.mpv = mpv
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { MPVLayer(mpv: mpv) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer?.requestDraw(force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer?.requestDraw(force: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        videoLayer?.requestDraw(force: true)
    }

    func destroyRender() { videoLayer?.destroyRender() }
}

final class MPVLayer: CAOpenGLLayer {
    private let mpv: OpaquePointer
    private var renderCtx: OpaquePointer?
    private var cglContext: CGLContextObj?
    private let queue = DispatchQueue(label: "hdtvmate.mpv.gl")
    private let state = NSLock()
    private var forceDraw = true
    private var pending = false            // a display() is already queued
    var renderStatus = "render context not created"
    var drawCount = 0

    init(mpv: OpaquePointer) {
        self.mpv = mpv
        super.init()
        isAsynchronous = false
        isOpaque = true
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {               // used by Core Animation for presentation copies
        let other = layer as! MPVLayer
        mpv = other.mpv
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var pf: CGLPixelFormatObj? = nil
        var n: GLint = 0
        CGLChoosePixelFormat(attrs, &pf, &n)
        if let pf = pf { return pf }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx: CGLContextObj = super.copyCGLContext(forPixelFormat: pf)
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLSetCurrentContext(ctx)
        cglContext = ctx
        setupRender()
        return ctx
    }

    private func setupRender() {
        guard renderCtx == nil else { return }
        let getProc: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name = name else { return nil }
            let sym = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
            let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
            return CFBundleGetFunctionPointerForName(bundle, sym)
        }
        var glInit = mpv_opengl_init_params()
        glInit.get_proc_address = getProc
        glInit.get_proc_address_ctx = nil
        let api = strdup("opengl")
        withUnsafeMutablePointer(to: &glInit) { glp in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glp)),
                mpv_render_param(),
            ]
            let rc = mpv_render_context_create(&renderCtx, mpv, &params)
            if rc < 0 { NSLog("HDTV Mate: mpv render context failed (%d)", rc) }
            renderStatus = rc < 0 ? "render context FAILED (\(rc))" : "render context ok"
        }
        free(api)
        guard let rc = renderCtx else { return }
        mpv_render_context_set_update_callback(rc, { ctx in
            guard let ctx = ctx else { return }
            Unmanaged<MPVLayer>.fromOpaque(ctx).takeUnretainedValue().requestDraw(force: false)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Any thread. Queues one redraw on the GL queue (coalesced).
    func requestDraw(force: Bool) {
        state.lock()
        if force { forceDraw = true }
        let already: Bool = pending
        pending = true
        state.unlock()
        if already { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.state.lock(); self.pending = false; self.state.unlock()
            self.display()
            CATransaction.flush()
        }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        state.lock()
        let force: Bool = forceDraw
        state.unlock()
        guard let rc = renderCtx else { return true }
        let flags: UInt64 = mpv_render_context_update(rc)
        return force || (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        state.lock(); forceDraw = false; state.unlock()
        CGLSetCurrentContext(ctx)
        var vp: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &vp)
        if let rc = renderCtx, vp[2] > 0, vp[3] > 0 {
            var fbo: GLint = 0
            glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
            var data = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(vp[2]), h: Int32(vp[3]), internal_format: 0)
            var flip: Int32 = 1
            withUnsafeMutablePointer(to: &data) { dp in
                withUnsafeMutablePointer(to: &flip) { fp in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(dp)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(fp)),
                        mpv_render_param(),
                    ]
                    _ = mpv_render_context_render(rc, &params)
                }
            }
            drawCount += 1
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
        if let rc = renderCtx { mpv_render_context_report_swap(rc) }
    }

    func destroyRender() {
        queue.sync {
            guard let rc = renderCtx else { return }
            if let c = cglContext { CGLLockContext(c); CGLSetCurrentContext(c) }
            mpv_render_context_set_update_callback(rc, nil, nil)
            mpv_render_context_free(rc)
            renderCtx = nil
            if let c = cglContext { CGLUnlockContext(c) }
        }
    }
}
