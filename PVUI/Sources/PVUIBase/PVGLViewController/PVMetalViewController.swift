//
//  PVMetalViewController.swift
//  Provenance
//
//  Created by Joseph Mattiello on 5/27/24.
//  Copyright © 2024 Provenance Emu. All rights reserved.
//

import Foundation
import Metal
import MetalKit
import IOSurface
import PVSupport
import PVEmulatorCore
import PVLogging
import PVSettings
import PVUIObjC

#if os(macOS) || targetEnvironment(macCatalyst)
import OpenGL
#else
import OpenGLES
import OpenGLES.EAGL
import OpenGLES.EAGLDrawable
import OpenGLES.EAGLIOSurface
import OpenGLES.ES3
import OpenGLES.gltypes
#endif

fileprivate let BUFFER_COUNT: UInt = 3

extension GLenum {
    var toString: String {
        switch self {
        case GLenum(GL_UNSIGNED_BYTE): return "GL_UNSIGNED_BYTE"
        case GLenum(GL_BGRA): return "GL_BGRA"
        case GLenum(GL_RGBA): return "GL_RGBA"
        case GLenum(GL_RGB): return "GL_RGB"
        case GLenum(GL_RGB8): return "GL_RGB8"
        case GLenum(0x8367): return "GL_UNSIGNED_INT_8_8_8_8_REV"
        // Add more cases as needed
        default: return String(format: "0x%04X", self)
        }
    }
}

final
class PVMetalViewController : PVGPUViewController, PVRenderDelegate, MTKViewDelegate {
    var presentationFramebuffer: AnyObject? = nil

    weak var emulatorCore: PVEmulatorCore? = nil

    #if !os(visionOS)
    var mtlView: MTKView!
    #endif

#if os(macOS) || targetEnvironment(macCatalyst)
//    var isPaused: Bool = false
//    var timeSinceLastDraw: TimeInterval = 0
//    var framesPerSecond: Double = 0
#endif


    // MARK: Internal

    var alternateThreadFramebufferBack: GLuint = 0
    var alternateThreadColorTextureBack: GLuint = 0
    var alternateThreadDepthRenderbuffer: GLuint = 0

    var backingIOSurface: IOSurfaceRef?    // for OpenGL core support
    var backingMTLTexture: (any MTLTexture)?   // for OpenGL core support

    var uploadBuffer: [MTLBuffer] = .init() // BUFFER_COUNT
    var frameCount: UInt = 0

    var renderSettings: RenderSettings = .init()

    // MARK: Internal properties

    var  device: MTLDevice? = nil
    var  commandQueue: MTLCommandQueue? = nil
    var  blitPipeline: MTLRenderPipelineState? = nil

    var  effectFilterPipeline: MTLRenderPipelineState? = nil
    var  pointSampler: MTLSamplerState? = nil
    var  linearSampler: MTLSamplerState? = nil

    var  inputTexture: MTLTexture? = nil
    var  previousCommandBuffer: MTLCommandBuffer? = nil // used for scheduling with OpenGL context

#if !os(macOS) && !targetEnvironment(macCatalyst)
    var  glContext: EAGLContext?
    var  alternateThreadGLContext: EAGLContext?
    var  alternateThreadBufferCopyGLContext: EAGLContext?
#elseif !targetEnvironment(macCatalyst)
    var  glContext: NSOpenGLContext?
    var  alternateThreadGLContext: NSOpenGLContext?
    var  alternateThreadBufferCopyGLContext: NSOpenGLContext?
    var  caDisplayLink: CADisplayLink?
#endif

    var  glesVersion: GLESVersion = .version3
    var  effectFilterShader: Shader? = nil

    // MARK: Internal GL status

    var resolution_uniform: GLuint = 0
    var texture_uniform: GLuint = 0
    var previous_texture_uniform: GLuint = 0
    var frame_blending_mode_uniform: GLuint = 0

    var position_attribute: GLuint = 0
    var texture: GLuint = 0
    var previous_texture: GLuint = 0
    var program: GLuint = 0

    // MARK: Methods

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required
    init(withEmulatorCore emulatorCore: PVEmulatorCore) {
        self.emulatorCore = emulatorCore

        super.init(nibName: nil, bundle: nil)

        if emulatorCore.rendersToOpenGL {
            emulatorCore.renderDelegate = self
        }

        renderSettings.crtFilterEnabled = filterShaderEnabled()
        renderSettings.lcdFilterEnabled = Defaults[.lcdFilterEnabled]
        renderSettings.smoothingEnabled = Defaults[.imageSmoothing]

        Task {
            for await value in Defaults.updates([.crtFilterEnabled, .lcdFilterEnabled, .imageSmoothing]) {
                renderSettings.crtFilterEnabled = Defaults[.crtFilterEnabled]
                renderSettings.lcdFilterEnabled = Defaults[.lcdFilterEnabled]
                renderSettings.smoothingEnabled = Defaults[.imageSmoothing]
            }
        }
    }


    deinit {
        if alternateThreadDepthRenderbuffer > 0 {
            glDeleteRenderbuffers(1, &alternateThreadDepthRenderbuffer)
        }
        if alternateThreadColorTextureBack > 0 {
            glDeleteTextures(1, &alternateThreadColorTextureBack)
        }
        if alternateThreadFramebufferBack > 0 {
            glDeleteFramebuffers(1, &alternateThreadFramebufferBack)
        }

        backingMTLTexture = nil
        if let backingIOSurface = backingIOSurface {
            IOSurfaceDecrementUseCount(backingIOSurface)
        }
    }

    func filterShaderEnabled() -> Bool {
        let value = Defaults[.metalFilter].lowercased()
        return !(value == "" || value == "off")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

#if !(targetEnvironment(macCatalyst) || os(macOS))
        if emulatorCore?.rendersToOpenGL ?? false {
            glContext = bestContext

            ILOG("Initiated GLES version \(String(describing: glContext?.api))")

            glContext?.isMultiThreaded = Defaults[.multiThreadedGL]

            EAGLContext.setCurrent(glContext)
        }
#endif

        frameCount = 0
        device = MTLCreateSystemDefaultDevice()

        let metalView = MTKView(frame: view.bounds, device: device)
        self.mtlView = metalView
        view.addSubview(mtlView)
        metalView.device = device
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.depthStencilPixelFormat = .depth32Float_stencil8
        metalView.sampleCount = 1
        metalView.delegate = self
        metalView.autoResizeDrawable = true
        commandQueue = device?.makeCommandQueue()

        // Set paused and only trigger redraw when needs display is set.
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        view.isOpaque = true
        view.layer.isOpaque = true

        view.isUserInteractionEnabled = false

        updatePreferredFPS()

        if let emulatorCore = emulatorCore {
            let depthFormat: Int32 = Int32(emulatorCore.depthFormat)
            switch depthFormat {
            case GL_DEPTH_COMPONENT16:
                metalView.depthStencilPixelFormat = .depth16Unorm
            case GL_DEPTH_COMPONENT24:
                metalView.depthStencilPixelFormat = .x32_stencil8
#if !(targetEnvironment(macCatalyst) || os(iOS) || os(tvOS) || os(watchOS))
                if device?.isDepth24Stencil8PixelFormatSupported ?? false {
                    view.depthStencilPixelFormat = .x24_stencil8
                }
#endif
            default:
                break
            }
        }

        if Defaults[.nativeScaleEnabled] {
            let scale = UIScreen.main.scale
            if scale != 1 {
                view.layer.contentsScale = scale
                view.layer.rasterizationScale = scale
                view.contentScaleFactor = scale
            }
        }

        setupTexture()
        setupBlitShader()

        let metalFilter = Defaults[.metalFilter]
        if let filterShader = MetalShaderManager.shared.filterShader(forName: metalFilter) {
            setupEffectFilterShader(filterShader)
        }

        alternateThreadFramebufferBack = 0
        alternateThreadColorTextureBack = 0
        alternateThreadDepthRenderbuffer = 0
    }

#if !(targetEnvironment(macCatalyst) || os(macOS))

    lazy var bestContext: EAGLContext? = {
        if let context = EAGLContext(api: .openGLES3) {
            glesVersion = .version3
            return context
        } else if let context = EAGLContext(api: .openGLES2) {
            glesVersion = .version2
            return context
        } else if let context = EAGLContext(api: .openGLES1) {
            glesVersion = .version1
            return context
        } else {
            return nil
        }
    }()
#endif

    func updatePreferredFPS() {
        let preferredFPS: Int = Int(emulatorCore?.frameInterval ?? 0)
        ILOG("updatePreferredFPS (\(preferredFPS))")
        if preferredFPS < 10 {
            WLOG("Cores frame interval (\(preferredFPS)) too low. Setting to 60")
            mtlView.preferredFramesPerSecond = 60
        } else {
            mtlView.preferredFramesPerSecond = preferredFPS
        }
    }

#if !(targetEnvironment(macCatalyst) || os(macOS))
    //    override func preferredFramesPerSecond(_ preferredFramesPerSecond: Int) {
    //        super.preferredFramesPerSecond(preferredFramesPerSecond)
    //    }
#else
    override var framesPerSecond: Double {
        get { super.framesPerSecond }
        set { super.framesPerSecond = newValue }
    }
#endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard let emulatorCore = emulatorCore else {
            return
        }

        if emulatorCore.skipLayout {
            return
        }

        let parentSafeAreaInsets = parent?.view.safeAreaInsets ?? .zero

        if !emulatorCore.screenRect.isEmpty {
            let aspectSize = emulatorCore.aspectSize
            var ratio: CGFloat = 0
            if aspectSize.width > aspectSize.height {
                ratio = aspectSize.width / aspectSize.height
            } else {
                ratio = aspectSize.height / aspectSize.width
            }

            var parentSize = parent?.view.bounds.size ?? CGSize.zero
            if let window = view.window {
                parentSize = window.bounds.size
            }

            var height: CGFloat = 0
            var width: CGFloat = 0

            if parentSize.width > parentSize.height {
                if Defaults[.integerScaleEnabled] {
                    height = floor(parentSize.height / aspectSize.height) * aspectSize.height
                } else {
                    height = parentSize.height
                }
                width = height * ratio
                if width > parentSize.width {
                    width = parentSize.width
                    height = width / ratio
                }
            } else {
                if Defaults[.integerScaleEnabled] {
                    width = floor(parentSize.width / aspectSize.width) * aspectSize.width
                } else {
                    width = parentSize.width
                }
                height = width / ratio
                if height > parentSize.height {
                    height = parentSize.width
                    width = height / ratio
                }
            }

            var origin = CGPoint(x: (parentSize.width - width) / 2, y: 0)
            if traitCollection.userInterfaceIdiom == .phone && parentSize.height > parentSize.width {
                origin.y = parentSafeAreaInsets.top + 40 // below menu button
            } else {
                origin.y = (parentSize.height - height) / 2 // centered
            }

            view.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
            mtlView.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        }

        updatePreferredFPS()
    }

    func updateInputTexture() {
        guard let emulatorCore = emulatorCore else {
            ELOG("emulatorCore is nil in updateInputTexture()")
            return
        }

        let screenRect = emulatorCore.screenRect
        let pixelFormat = getMTLPixelFormat(from: emulatorCore.pixelFormat,
                                               type: emulatorCore.pixelType)

        ILOG("Updating input texture with screenRect: \(screenRect), pixelFormat: \(pixelFormat)")

        #if targetEnvironment(simulator)
        var mtlPixelFormat: MTLPixelFormat = .astc_6x5_srgb
        #else
        var mtlPixelFormat: MTLPixelFormat = pixelFormat
        #endif
        if emulatorCore.rendersToOpenGL {
            mtlPixelFormat = .rgba8Unorm
        }

        if inputTexture == nil ||
            inputTexture?.width != Int(screenRect.width) ||
            inputTexture?.height != Int(screenRect.height) ||
            inputTexture?.pixelFormat != mtlPixelFormat {

            let desc = MTLTextureDescriptor()
            desc.textureType = .type2D
            desc.pixelFormat = mtlPixelFormat
            desc.width = Int(screenRect.width)
            desc.height = Int(screenRect.height)
            desc.storageMode = .private
            desc.usage = .shaderRead

            inputTexture = device?.makeTexture(descriptor: desc)

            if let inputTexture = inputTexture {
                ILOG("Created new input texture with size: \(inputTexture.width)x\(inputTexture.height), format: \(inputTexture.pixelFormat)")
            } else {
                ELOG("Failed to create input texture")
            }
        }
    }

    // TODO: Make throw
    func setupTexture() {
        precondition(emulatorCore != nil)
        precondition(device != nil)

        guard let emulatorCore = emulatorCore else {
            ELOG("emulatorCore is nil")
            return
        }

        guard let device = device else {
            ELOG("device is nil")
            return
        }

        updateInputTexture()

        if !emulatorCore.rendersToOpenGL {
            let formatByteWidth = getByteWidth(for: Int32(emulatorCore.pixelFormat),
                                               type: Int32(emulatorCore.pixelType))

            for i in 0..<BUFFER_COUNT {
                let length = emulatorCore.bufferSize.width * emulatorCore.bufferSize.height * CGFloat(formatByteWidth)
                if length != 0 {
                    let newBuffer = device.makeBuffer(length: Int(length), options: .storageModeShared)!
                    uploadBuffer.append(newBuffer)
                    //uploadBuffer[Int(i)] =
                } else {
                    let bufferSize = emulatorCore.bufferSize
                    ELOG("Invalid buffer size: Should be non-zero. Is <\(bufferSize.width),\(bufferSize.height)>")
                }
            }
        }

        let pointDesc = MTLSamplerDescriptor()
        pointDesc.minFilter = .nearest
        pointDesc.magFilter = .nearest
        pointDesc.mipFilter = .nearest
        pointDesc.sAddressMode = .clampToZero
        pointDesc.tAddressMode = .clampToZero
        pointDesc.rAddressMode = .clampToZero

        pointSampler = device.makeSamplerState(descriptor: pointDesc)

        let linearDesc = MTLSamplerDescriptor()
        linearDesc.minFilter = .linear
        linearDesc.magFilter = .linear
        linearDesc.mipFilter = .nearest
        linearDesc.sAddressMode = .clampToZero
        linearDesc.tAddressMode = .clampToZero
        linearDesc.rAddressMode = .clampToZero

        linearSampler = device  .makeSamplerState(descriptor: linearDesc)
    }

    func getByteWidth(for pixelFormat: Int32, type pixelType: Int32) -> UInt {
        return getByteWidthNeo(for: pixelFormat, type: pixelType)
    }
    func getByteWidthLegacy(for pixelFormat: Int32, type pixelType: Int32) -> UInt {
        var typeWidth: UInt = 0
        switch pixelType {
        case GL_BYTE, GL_UNSIGNED_BYTE:
            typeWidth = 2
        case GL_UNSIGNED_SHORT_5_5_5_1, GL_SHORT, GL_UNSIGNED_SHORT, GL_UNSIGNED_SHORT_5_6_5:
            typeWidth = 2
        case GL_INT, GL_UNSIGNED_INT, GL_FLOAT, GL_FLOAT_32_UNSIGNED_INT_24_8_REV, 0x8367: // GL_UNSIGNED_INT_8_8_8_8_REV:
            typeWidth = 4
        default:
            assertionFailure("Unknown GL pixelType. Add me")
        }

        switch pixelFormat {
        case GL_BGRA, GL_RGBA:
            switch pixelType {
            case GL_UNSIGNED_BYTE:
                return 2 * typeWidth
            case GL_UNSIGNED_SHORT_4_4_4_4, GL_UNSIGNED_SHORT_5_5_5_1, GL_UNSIGNED_SHORT_5_6_5:
                return 2 * typeWidth
            default:
                return 4 * typeWidth
            }
        //    #if !TARGET_OS_MACCATALYST && !TARGET_OS_OSX
        case GL_RGB565, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, GL_RGB:
        //    #else
        //          case GL_UNSIGNED_SHORT_5_6_5, GL_RGB:
        //    #endif
            switch pixelType {
            case GL_UNSIGNED_BYTE, GL_UNSIGNED_SHORT_4_4_4_4, GL_UNSIGNED_SHORT_5_5_5_1, GL_UNSIGNED_SHORT_5_6_5:
                return typeWidth
            default:
                return 4 * typeWidth
            }
        case GL_RGB5_A1:
            return 4 * typeWidth
        case GL_RGB8, GL_RGBA8:
            return 8 * typeWidth
        default:
            break;
        }

        assertionFailure("Unknown GL pixelFormat %x. Add me: \(pixelFormat)")
        return 1
    }

    func getByteWidthNeo(for pixelFormat: Int32, type pixelType: Int32) -> UInt {
        // Determine component size
        let componentSize: Int
        switch pixelType {
        case GL_BYTE, GL_UNSIGNED_BYTE:
            componentSize = 1
        case GL_SHORT, GL_UNSIGNED_SHORT, GL_UNSIGNED_SHORT_5_6_5, GL_UNSIGNED_SHORT_4_4_4_4, GL_UNSIGNED_SHORT_5_5_5_1:
            componentSize = 2
        case GL_INT, GL_UNSIGNED_INT, GL_FLOAT, GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
            componentSize = 4
        case 0x8367: // GL_UNSIGNED_INT_8_8_8_8_REV
            return 4 // This is always 4 bytes per pixel
        default:
            WLOG("Warning: Unknown GL pixelType: \(pixelType)")
            return 0
        }

        // Handle special cases first
        switch (pixelFormat, pixelType) {
        case (_, GL_UNSIGNED_SHORT_5_6_5),
             (_, GL_UNSIGNED_SHORT_4_4_4_4),
             (_, GL_UNSIGNED_SHORT_5_5_5_1):
            return 2
        case (GL_RGBA8, _):
            return 4
        case (GL_RGB8, _):
            return 3 // Note: This might be 4 in practice due to alignment, but technically it's 3 bytes
        case (GL_RGB5_A1, _):
            return 2
        default:
            break
        }

        // Determine components per pixel
        let componentsPerPixel: Int
        switch pixelFormat {
        case GL_RGBA, GL_BGRA, GL_RGBA8:
            componentsPerPixel = 4
        case GL_RGB, GL_RGB565, GL_RGB8:
            componentsPerPixel = 3
        case GL_LUMINANCE_ALPHA:
            componentsPerPixel = 2
        case GL_LUMINANCE, GL_ALPHA:
            componentsPerPixel = 1
        case GL_R8:
            componentsPerPixel = 1
        case GL_RG8:
            componentsPerPixel = 2
        default:
            WLOG("Warning: Unknown GL pixelFormat: \(pixelFormat)")
            assertionFailure("Warning: Unknown GL pixelFormat: \(pixelFormat)")
            return 1
        }

        return UInt(componentSize * componentsPerPixel)
    }


    func getMTLPixelFormat(from pixelFormat: GLenum, type pixelType: GLenum) -> MTLPixelFormat {
        return getMTLPixelFormatNeo(from: pixelFormat, type: pixelType)
    }

    func getMTLPixelFormatNeo(from pixelFormat: GLenum, type pixelType: GLenum) -> MTLPixelFormat {
        VLOG("Getting MTLPixelFormat for pixelFormat: \(pixelFormat.toString), pixelType: \(pixelType.toString)")
        switch (pixelFormat, pixelType) {
        case (GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE)),
             (GLenum(GL_BGRA), GLenum(0x8367)): // GL_UNSIGNED_INT_8_8_8_8_REV
            return .bgra8Unorm
        case (GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT)):
            return .bgra8Unorm
        case (GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE)),
             (GLenum(GL_RGBA8), GLenum(GL_UNSIGNED_BYTE)):
            return .rgba8Unorm
        case (GLenum(GL_RGBA), GLenum(GL_BYTE)):
            return .rgba8Snorm
        case (GLenum(GL_RGB), GLenum(GL_UNSIGNED_BYTE)),
             (GLenum(GL_RGB8), GLenum(GL_UNSIGNED_BYTE)):
            // Note: Metal doesn't have a direct RGB8 format, using RGBA8 and ignoring alpha
            return .rgba8Unorm
        case (GLenum(GL_RGB), GLenum(GL_UNSIGNED_SHORT)):
            return .rgb10a2Unorm // Better match for RGB unsigned short
        case (GLenum(GL_RGB), GLenum(GL_UNSIGNED_SHORT_5_6_5)),
            (GLenum(GL_BGRA), GLenum(GL_UNSIGNED_SHORT_5_6_5)):
            return .b5g6r5Unorm
        case (GLenum(GL_RGB), GLenum(GL_UNSIGNED_INT)):
            return .rgba32Uint // Approximation, might lose precision
        case (_, GLenum(GL_UNSIGNED_SHORT_8_8_APPLE)):
            return .rg8Unorm // Approximation, might need custom handling
        case (_, GLenum(GL_UNSIGNED_SHORT_5_5_5_1)):
            return .a1bgr5Unorm
        case (_, GLenum(GL_UNSIGNED_SHORT_4_4_4_4)):
            return .abgr4Unorm
        case (GLenum(GL_RGBA8), GLenum(GL_UNSIGNED_SHORT)):
            return .rgba16Uint
        case (GLenum(GL_RGBA8), GLenum(GL_UNSIGNED_INT)):
            return .rgba32Uint
        case (GLenum(GL_R8), _):
            return .r8Unorm
        case (GLenum(GL_RG8), _):
            return .rg8Unorm
        #if !targetEnvironment(macCatalyst) && !os(macOS)
        case (GLenum(GL_RGB565), _):
            return .b5g6r5Unorm
        #else
        case (GLenum(GL_UNSIGNED_SHORT_5_6_5), _):
            return .b5g6r5Unorm
        #endif
        // Add more cases as needed for your specific use cases
        default:
            WLOG("Unknown GL pixelFormat: \(pixelFormat.toString), pixelType: \(pixelType.toString). Defaulting to .rgba8Unorm")
            return .rgba8Unorm
        }
    }

    func getMTLPixelFormatLegacy(from pixelFormat: GLenum, type pixelType: GLenum) -> MTLPixelFormat {
        if pixelFormat == GLenum(GL_BGRA),
           pixelType == GLenum(GL_UNSIGNED_BYTE) ||
            pixelType == GLenum(0x8367) {
            return .bgra8Unorm
        }
        else if pixelFormat == GLenum(GL_BGRA),
                    pixelType == GLenum(GL_UNSIGNED_BYTE) {
            return .bgra8Unorm
        }
        else if pixelFormat == GLenum(GL_BGRA),
                pixelType == GLenum(GL_UNSIGNED_INT) {
            return .bgra8Unorm_srgb
        }
        else if pixelFormat == GLenum(GL_BGRA),
                  pixelType == GLenum(GL_FLOAT_32_UNSIGNED_INT_24_8_REV) {
            return .bgra8Unorm_srgb
        }
        else if pixelFormat == GLenum(GL_RGBA),
                    pixelType == GLenum(GL_UNSIGNED_BYTE) {
            return .rgba8Unorm
        }
        else if pixelFormat == GLenum(GL_RGBA),
                    pixelType == GLenum(GL_BYTE) {
            return .rgba8Snorm
        }
        else if pixelFormat == GLenum(GL_RGB),
                    pixelType == GLenum(GL_UNSIGNED_BYTE) {
            return .rgba8Unorm
        }
        else if pixelFormat == GLenum(GL_RGB),
                    pixelType == GLenum(GL_UNSIGNED_SHORT) {
            return .rgba16Uint
        }
        else if pixelFormat == GLenum(GL_RGB),
                    pixelType == GLenum(GL_UNSIGNED_SHORT_5_6_5) {
            return .b5g6r5Unorm
        }
        else if pixelFormat == GLenum(GL_RGB),
                    pixelType == GLenum(GL_UNSIGNED_INT) {
            return .rgba16Unorm
        }
        else if pixelType == GLenum(GL_UNSIGNED_SHORT_8_8_APPLE) {
            return .rgba16Unorm
        }
        else if pixelType == GLenum(GL_UNSIGNED_SHORT_5_5_5_1) {
            return .a1bgr5Unorm
        }
        else if pixelType == GLenum(GL_UNSIGNED_SHORT_4_4_4_4) {
            return .abgr4Unorm
        }
        else if pixelFormat == GLenum(GL_RGBA8) {
            if pixelType == GLenum(GL_UNSIGNED_BYTE) {
                return .rgba8Unorm
            } else if pixelType == GLenum(GL_UNSIGNED_SHORT) {
                return .rgba16Uint
            } else if pixelType == GLenum(GL_UNSIGNED_INT) {
                return .rgba32Uint
            }
        }
#if !targetEnvironment(macCatalyst) && !os(macOS)
        if pixelFormat == GLenum(GL_RGB565) {
            return .b5g6r5Unorm //.rgba16Unorm
        }
#else
        if pixelFormat == GLenum(GL_UNSIGNED_SHORT_5_6_5) {
            return .rgba16Unorm
        }
#endif
        print("Error: Unknown GL pixelFormat. Add pixelFormat: \(pixelFormat) pixelType: \(pixelType)")
        assertionFailure("Unknown GL pixelFormat. Add pixelFormat: \(pixelFormat) pixelType: \(pixelType)")
        return .invalid
    }

    // TODO: Make this throw
    func setupBlitShader() {
        guard let emulatorCore = emulatorCore else {
            ELOG("emulatorCore is nil in setupBlitShader()")
            return
        }

        guard let device = device else {
            ELOG("device is nil in setupBlitShader()")
            return
        }

        let constants = MTLFunctionConstantValues()
        var flipY = emulatorCore.rendersToOpenGL
        constants.setConstantValue(&flipY, type: .bool, withName: "FlipY")

        guard let lib = device.makeDefaultLibrary() else {
            ELOG("Failed to create default library")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        guard let fillScreenShader = MetalShaderManager.shared.vertexShaders.first else {
            ELOG("No fill screen shader found")
            return
        }

        do {
            desc.vertexFunction = try lib.makeFunction(name: fillScreenShader.function, constantValues: constants)
        } catch let error {
            ELOG("Error creating vertex function: \(error)")
        }

        guard let blitterShader = MetalShaderManager.shared.blitterShaders.first else {
            ELOG("No blitter shader found")
            return
        }

        desc.fragmentFunction = lib.makeFunction(name: blitterShader.function)

        if let currentDrawable = mtlView.currentDrawable {
            desc.colorAttachments[0].pixelFormat = currentDrawable.texture.pixelFormat
        } else {
            ELOG("No current drawable available")
        }

        do {
            blitPipeline = try device.makeRenderPipelineState(descriptor: desc)
            ILOG("Successfully created blit pipeline state")
        } catch let error {
            ELOG("Error creating render pipeline state: \(error)")
        }
    }

    // TODO: Make this throw
    func setupEffectFilterShader(_ filterShader: Shader) {
        guard let emulatorCore = emulatorCore else {
            ELOG("emulatorCore is nil")
            return
        }

        guard let device = device else {
            ELOG("device is nil")
            return
        }

        effectFilterShader = filterShader

        let constants = MTLFunctionConstantValues()
        var flipY = emulatorCore.rendersToOpenGL
        constants.setConstantValue(&flipY, type: .bool, withName: "FlipY")

        guard let lib = device.makeDefaultLibrary() else {
            ELOG("Failed to create default library")
            return
        }

        // Fill screen shader
        let desc = MTLRenderPipelineDescriptor()
        guard let fillScreenShader = MetalShaderManager.shared.vertexShaders.first else {
            ELOG("No fill screen shader found")
            return
        }

        do {
            desc.vertexFunction = try lib.makeFunction(name: fillScreenShader.function, constantValues: constants)
        } catch let error {
            ELOG("Error creating vertex function: \(error)")
        }

        // Filter shader
        desc.fragmentFunction = lib.makeFunction(name: filterShader.function)

        if let currentDrawable = mtlView.currentDrawable {
            desc.colorAttachments[0].pixelFormat = currentDrawable.layer.pixelFormat
        }

        do {
            effectFilterPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch let error {
            ELOG("Error creating render pipeline state: \(error)")
        }
    }


    class func shader(withContents contents: String, type: GLenum) -> GLuint {
        let source = (contents as NSString).utf8String

        // Create the shader object
        let shader = glCreateShader(type)

        // Load the shader source
        var sourcePointer = source
        glShaderSource(shader, 1, &sourcePointer, nil)

        // Compile the shader
        glCompileShader(shader)

        // Check for errors
        var status: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)

        if status == GLint(GL_FALSE) {
            var messages = [GLchar](repeating: 0, count: 1024)
            glGetShaderInfoLog(shader, GLsizei(messages.count), nil, &messages)
            let messageString = String(cString: messages)
            ELOG("\(Self.self) - GLSL Shader Error: \(messageString)")
        }

        return shader
    }

    class func program(vertexShader vsh: String, fragmentShader fsh: String) -> GLuint {
        // Build shaders
        let vertexShader = Self.shader(withContents: vsh, type: GLenum(GL_VERTEX_SHADER))
        let fragmentShader = Self.shader(withContents: fsh, type: GLenum(GL_FRAGMENT_SHADER))

        // Create program
        let program = glCreateProgram()

        // Attach shaders
        glAttachShader(program, vertexShader)
        glAttachShader(program, fragmentShader)

        // Link program
        glLinkProgram(program)

        // Check for errors
        var status: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &status)

        if status == GLint(GL_FALSE) {
            var messages = [GLchar](repeating: 0, count: 1024)
            glGetProgramInfoLog(program, GLsizei(messages.count), nil, &messages)
            let messageString = String(cString: messages)
            ELOG("\(Self.self) - GLSL Program Error: \(messageString)")
        }

        // Delete shaders
        glDeleteShader(vertexShader)
        glDeleteShader(fragmentShader)

        return program
    }


    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // no-op
        DLOG("drawableSizeWillChange: \(size), UNSUPPORTED")
    }

    @inlinable
    func draw(in view: MTKView) {
        guard let emulatorCore = emulatorCore else {
            ELOG("EmulatorCore is nil")
            return
        }

        if emulatorCore.skipEmulationLoop {
            return
        }

        if emulatorCore.rendersToOpenGL {
            if !emulatorCore.isSpeedModified && !emulatorCore.isEmulationPaused || emulatorCore.isFrontBufferReady {
                emulatorCore.frontBufferCondition.lock()
                while !emulatorCore.isFrontBufferReady && !emulatorCore.isEmulationPaused {
                    emulatorCore.frontBufferCondition.wait()
                }
                let isFrontBufferReady = emulatorCore.isFrontBufferReady
                emulatorCore.frontBufferCondition.unlock()
                if isFrontBufferReady {
                    self._render(emulatorCore, in: view)
                    emulatorCore.frontBufferCondition.lock()
                    emulatorCore.isFrontBufferReady = false
                    emulatorCore.frontBufferCondition.signal()
                    emulatorCore.frontBufferCondition.unlock()
                }
            }
        } else {
            if emulatorCore.isSpeedModified {
                self._render(emulatorCore, in: view)
            } else if emulatorCore.isDoubleBuffered {
                emulatorCore.frontBufferCondition.lock()
                while !emulatorCore.isFrontBufferReady && !emulatorCore.isEmulationPaused {
                    emulatorCore.frontBufferCondition.wait()
                }
                emulatorCore.isFrontBufferReady = false
                emulatorCore.frontBufferLock.lock()
                self._render(emulatorCore, in: view)
                emulatorCore.frontBufferLock.unlock()
                emulatorCore.frontBufferCondition.unlock()
            } else {
                objc_sync_enter(emulatorCore)
                self._render(emulatorCore, in: view)
                objc_sync_exit(emulatorCore)
            }
        }
    }

    @inlinable
    @inline(__always)
    func _render(_ emulatorCore: PVEmulatorCore, in view: MTKView) {
        guard let outputTexture = view.currentDrawable?.texture else {
            return
        }

        if emulatorCore.rendersToOpenGL {
            emulatorCore.frontBufferLock.lock()
        }

//        VLOG("Drawing frame with pixelFormat: \(emulatorCore.pixelFormat.toString), pixelType: \(emulatorCore.pixelType.toString), internalPixelFormat: \(emulatorCore.internalPixelFormat.toString)")

        guard let commandBuffer = self.commandQueue?.makeCommandBuffer() else {
            ELOG("Failed to create command buffer")
            return
        }
        self.previousCommandBuffer = commandBuffer

        let screenRect = emulatorCore.screenRect

        self.updateInputTexture()

        if !emulatorCore.rendersToOpenGL, let videoBuffer: UnsafeMutableRawPointer = emulatorCore.videoBuffer {
            let videoBufferSize = emulatorCore.bufferSize
            let formatByteWidth = self.getByteWidth(for: Int32(emulatorCore.pixelFormat), type: Int32(emulatorCore.pixelType))
            let inputBytesPerRow = UInt(videoBufferSize.width) * formatByteWidth

            let uploadBufferIndex = Int(self.frameCount % BUFFER_COUNT)
            self.frameCount += 1

            let uploadBuffer = self.uploadBuffer[uploadBufferIndex]
            let uploadAddress: UnsafeMutableRawPointer = uploadBuffer.contents()

            var outputBytesPerRow: UInt
            if screenRect.origin.x == 0 && (screenRect.width * 2 >= videoBufferSize.width) {
                /// fast path if x is aligned to edge and excess width isn't too crazy
                outputBytesPerRow = inputBytesPerRow
                let inputOffset: Int = Int(UInt(screenRect.origin.y) * inputBytesPerRow)
                let inputAddress = videoBuffer.advanced(by: inputOffset)
                memcpy(uploadAddress, inputAddress, Int(UInt(screenRect.height) * inputBytesPerRow))
            } else {
                outputBytesPerRow = UInt(screenRect.width) * formatByteWidth
                // memcpy for each scan line
                // TODO: Parallelize or SIMD me
                for i in 0..<Int(screenRect.height) {
                    let inputRow = screenRect.origin.y + CGFloat(i)
                    let inputOffset: Int = Int(inputRow * CGFloat(inputBytesPerRow)) + Int(screenRect.origin.x * CGFloat(formatByteWidth))
                    let inputAddress = videoBuffer.advanced(by: inputOffset)
                    let outputOffset: Int = i * Int(outputBytesPerRow)
                    let outputAddress = uploadAddress.advanced(by: outputOffset)
                    memcpy(outputAddress, inputAddress, Int(outputBytesPerRow))
                }
            }

            guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                ELOG("makeBlitCommandEncoder return nil")
                return
            }

            let sourceSize = MTLSize(width: Int(screenRect.width), height: Int(screenRect.height), depth: 1)
            encoder.copy(from: uploadBuffer,
                         sourceOffset: 0,
                         sourceBytesPerRow: Int(outputBytesPerRow),
                         sourceBytesPerImage: 0,
                         sourceSize: sourceSize,
                         to: self.inputTexture!,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))

            encoder.endEncoding()
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = outputTexture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else {
            ELOG("Failed to create render command encoder")
            return
        }

        var pipelineState: MTLRenderPipelineState?

        if self.renderSettings.lcdFilterEnabled, emulatorCore.screenType.isLCD {
            WLOG("LCD Filter not implemented yet")
            pipelineState = self.blitPipeline
        } else if self.renderSettings.crtFilterEnabled, emulatorCore.screenType.isCRT {
            if self.effectFilterShader?.name == "CRT" {
                let displayRect = SIMD4<Float>(Float(screenRect.origin.x), Float(screenRect.origin.y),
                                               Float(screenRect.width), Float(screenRect.height))
                let emulatedImageSize = SIMD2<Float>(Float(self.inputTexture!.width),
                                                     Float(self.inputTexture!.height))
                let finalRes = SIMD2<Float>(Float(view.drawableSize.width),
                                            Float(view.drawableSize.height))
                var cbData = CRT_Data(DisplayRect: displayRect, EmulatedImageSize: emulatedImageSize, FinalRes: finalRes)

                encoder.setFragmentBytes(&cbData, length: MemoryLayout<CRT_Data>.stride, index: 0)
                pipelineState = self.effectFilterPipeline
            } else if self.effectFilterShader?.name == "Simple CRT" {
                let mameScreenSrcRect: SIMD4<Float> = SIMD4<Float>.init(0, 0, Float(screenRect.size.width), Float(screenRect.size.height))
                let mameScreenDstRect: SIMD4<Float> = SIMD4<Float>.init(Float(inputTexture!.width), Float(inputTexture!.height), Float(view.drawableSize.width), Float(view.drawableSize.height))

                var cbData = SimpleCrtUniforms(
                    mameScreenDstRect: mameScreenSrcRect,
                    mameScreenSrcRect: mameScreenDstRect
                )

                cbData.curvVert = 5.0
                cbData.curvHoriz = 4.0
                cbData.curvStrength = 0.25
                cbData.lightBoost = 1.3
                cbData.vignStrength = 0.05
                cbData.zoomOut = 1.1
                cbData.brightness = 1.0

                encoder.setFragmentBytes(&cbData, length: MemoryLayout<SimpleCrtUniforms>.stride, index: 0)
                pipelineState = self.effectFilterPipeline
            }
        } else {
            pipelineState = self.blitPipeline
        }

        if let pipelineState = pipelineState {
            encoder.setRenderPipelineState(pipelineState)

            encoder.setFragmentTexture(self.inputTexture, index: 0)
            encoder.setFragmentSamplerState(self.renderSettings.smoothingEnabled ? self.linearSampler : self.pointSampler, index: 0)

//            VLOG("Drawing primitives with pipeline state: \(pipelineState)")
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.present(view.currentDrawable!)
            commandBuffer.commit()
        } else {
            ELOG("No valid pipeline state selected. Skipping draw call.")
            encoder.endEncoding()
            commandBuffer.commit()
        }

        if emulatorCore.rendersToOpenGL {
            emulatorCore.frontBufferLock.unlock()
        }
    }

    // MARK: - PVRenderDelegate
    func startRenderingOnAlternateThread() {
        emulatorCore?.glesVersion = glesVersion

#if !(targetEnvironment(macCatalyst) || os(macOS))
        guard let glContext = self.glContext else {
            ELOG("glContext was nil, cannot start rendering on alternate thread")
            return
        }
        alternateThreadBufferCopyGLContext = EAGLContext(api: glContext.api,
                                                         sharegroup: glContext.sharegroup)
        alternateThreadGLContext = EAGLContext(api: glContext.api,
                                               sharegroup: glContext.sharegroup)
        EAGLContext.setCurrent(alternateThreadGLContext)
#endif

        if alternateThreadFramebufferBack == 0 {
            glGenFramebuffers(1, &alternateThreadFramebufferBack)
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), alternateThreadFramebufferBack)

        if alternateThreadColorTextureBack == 0 {
            let width = emulatorCore?.bufferSize.width ?? 0
            let height = emulatorCore?.bufferSize.height ?? 0

            let dict: [CFString: Any] = [
                kIOSurfaceWidth: width,
                kIOSurfaceHeight: height,
                kIOSurfaceBytesPerElement: 4
            ]

            backingIOSurface = IOSurfaceCreate(dict as CFDictionary)
            IOSurfaceLock(backingIOSurface!, IOSurfaceLockOptions(rawValue: 0), nil)

            glGenTextures(1, &alternateThreadColorTextureBack)
            glBindTexture(GLenum(GL_TEXTURE_2D), alternateThreadColorTextureBack)

#if targetEnvironment(macCatalyst) || os(macOS)
            // TODO: This?
#warning("macOS incomplete")
#else
            EAGLContext.current()?.texImageIOSurface(backingIOSurface!,
                                                     target: UInt(GLenum(GL_TEXTURE_2D)),
                                                     internalFormat: UInt(GLenum(GL_RGBA)),
                                                     width: UInt32(GLsizei(width)),
                                                     height: UInt32(GLsizei(height)),
                                                     format: UInt(GLenum(GL_RGBA)),
                                                     type: UInt(GLenum(GL_UNSIGNED_BYTE)),
                                                     plane: 0)
#endif

            glBindTexture(GLenum(GL_TEXTURE_2D), 0)

            IOSurfaceUnlock(backingIOSurface!, IOSurfaceLockOptions(rawValue: 0), nil)

            let mtlDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                   width: Int(width),
                                                                   height: Int(height),
                                                                   mipmapped: false)
            backingMTLTexture = device?.makeTexture(descriptor: mtlDesc, iosurface: backingIOSurface!, plane: 0)
        }
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                               GLenum(GL_TEXTURE_2D), alternateThreadColorTextureBack, 0)

        if alternateThreadDepthRenderbuffer == 0 {
            glGenRenderbuffers(1, &alternateThreadDepthRenderbuffer)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), alternateThreadDepthRenderbuffer)
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH_COMPONENT16),
                                  GLsizei(emulatorCore?.bufferSize.width ?? 0),
                                  GLsizei(emulatorCore?.bufferSize.height ?? 0))
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT),
                                      GLenum(GL_RENDERBUFFER), alternateThreadDepthRenderbuffer)
        }

        glViewport(GLint(emulatorCore?.screenRect.origin.x ?? 0),
                   GLint(emulatorCore?.screenRect.origin.y ?? 0),
                   GLsizei(emulatorCore?.screenRect.size.width ?? 0),
                   GLsizei(emulatorCore?.screenRect.size.height ?? 0))
    }

    func didRenderFrameOnAlternateThread() {
        glFlush()

        emulatorCore?.frontBufferLock.lock()

        previousCommandBuffer?.waitUntilScheduled()

        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            ELOG("commandBuffer was nil")
            return
        }

        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            ELOG("encoder was nil")
            return
        }

        let screenRect = emulatorCore?.screenRect ?? .zero

        encoder.copy(from: backingMTLTexture!,
                     sourceSlice: 0, sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: Int(screenRect.origin.x),
                                             y: Int(screenRect.origin.y), z: 0),
                     sourceSize: MTLSize(width: Int(screenRect.width),
                                         height: Int(screenRect.height), depth: 1),
                     to: inputTexture!,
                     destinationSlice: 0, destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))

        encoder.endEncoding()
        commandBuffer.commit()

        emulatorCore?.frontBufferLock.unlock()

        emulatorCore?.frontBufferCondition.lock()
        emulatorCore?.isFrontBufferReady = true
        emulatorCore?.frontBufferCondition.signal()
        emulatorCore?.frontBufferCondition.unlock()
    }
}
