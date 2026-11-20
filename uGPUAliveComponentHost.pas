unit uGPUAliveComponentHost;

{*******************************************************************************
  GPUAliveComponentHost  v0.2
  ==============================================================================

  What is this?
  -------------
  An FMX control that renders its ENTIRE surface as one persistent GPU
  particle field. UI elements (labels, buttons, PNG icons) are NOT real
  sub-controls: they are attractor masks inside the same particle cloud.
  Every pixel of a UI element becomes one or more particles that are
  pulled to their home position by a spring-damper force.

  The result: buttons "breathe", labels shimmer, mouse movement stirs the
  particles up, clicks send shockwaves through the field - all on the GPU.

  Part of the "Alive" family: uGPUAliveGrid, uGPUAliveProgress, ...

  ==============================================================================
  ARCHITECTURE
  ==============================================================================

  The control derives from TSkiaCustomThreadedBase. The base provides a
  dedicated render thread that calls UpdateLogic() and RenderEffect() in
  a loop. The UI thread is never blocked - it only shows the finished
  Skia snapshot.

  OpenGL context:
  ---------------
  The GL 4.3 Core context lives on an INVISIBLE dummy window (WS_POPUP,
  16x16, never shown) and is created and used EXCLUSIVELY on the render
  thread. The UI thread never touches the context while the thread is
  alive.

  This order is CRITICAL and was the root cause of months of "black
  window despite running compute dispatches": a WGL context that is
  created and made current in thread A CANNOT simply be taken over by
  thread B. AMD drivers (atio6axx.dll) fail SILENTLY in that situation
  - no GL error, no crash, just 0% GPU load and a black image. Hence:
    - InitGL() only sets Active := True. No GL setup.
    - RenderEffect() calls InitOffscreenGL() at the top (on the render
      thread).
    - InitOffscreenGL() leaves the context CURRENT at the end.
    - RenderEffect() does NOT call wglMakeCurrent(0,0) at frame end.
    - Destroy() calls inherited BEFORE CleanupOffscreenGL, so the base
      thread joins first and the UI thread can then safely delete the
      context.

  Per-frame data flow (RenderEffect, all on the render thread):
  -------------------------------------------------------------
    1. InitOffscreenGL() on the very first frame (window, context,
       shaders, SSBO, textures, PBOs).
    2. UpdateSimResolution(): if the client exceeds the fullscreen
       threshold, FSimWidth/FSimHeight := ViewW/2, ViewH/2 (else 1:1).
       FParticleCount := TotalSimPixels*2, capped at PARTICLE_MAX (800k).
    3. ResizeTextures() if the control OR the sim resolution changed -
       texture, PBOs, layout mask and DIB all live at FSim* size.
    4. RebuildLayoutMaskIfNeeded() if FLayoutDirty (after Add/Update of
       a virtual control): GDI paints the controls into the sim-sized
       DIB (bounds scaled view->sim), an alpha-fix marks only painted
       pixels as opaque, the mask is copied into FLayoutMask, particles
       are bound to mask pixels. Ambient dust is seeded into the first
       MAX_AMBIENT_RATIO fraction of the SSBO once; uAmbientRatio
       selects the active subset at runtime (no rebuild on toggle).
    5. Async PBO readback of the PREVIOUS frame into FPixelBuffer
       (a quarter of the bytes in fullscreen).
    6. Decay pass (compute): output texture is darkened (trail fade).
    7. Particle pass (compute, local_size_x = 256): spring-damper +
       mouse + hover + click. Bound particles write directly via
       imageStore (no RMW); ambient dust adds softly via imageLoad.
    8. glGetTexImage into the next PBO (async, no pipeline stall).
    9. Blit FPixelBuffer as a Skia raster image, upscaled from
       (FSimWidth, FSimHeight) to (ViewW, ViewH) via
       TSkSamplingOptions.Medium.

  ==============================================================================
  SSBO LAYOUT (32 bytes per particle, std430)
  ==============================================================================

    vec2 pos       (8B)  current position in UV space [0..1]^2
    vec2 vel       (8B)  velocity in UV/second
    vec2 homePos   (8B)  target UV, or (-1,-1) for ambient particles
    uint color     (4B)  packed as 0xRRGGBBAA
    uint flags     (4B)  0 = ambient (free floating)
                         1 = bound to a control (label/button/png)

  Index layout (FIXED, independent of FAmbientDensity so toggling dust
  never needs a mask rebuild + SSBO re-upload):
    [0 .. AmbientMax-1)                          -> ambient dust pool
    [AmbientMax .. AmbientMax+FBoundCount-1)     -> bound mask particles
    [AmbientMax+FBoundCount .. FParticleCount-1] -> unused tail (ambient)

  AmbientMax = FParticleCount * MAX_AMBIENT_RATIO (0.5). The
  uAmbientRatio uniform then selects at runtime what fraction of the
  ambient pool is actually simulated: particles whose idx/uParticleCount
  exceeds uAmbientRatio return immediately in the shader.

  Ambient particles drift with sine noise and mouse repulsion. Bound
  particles are pulled to their homePos by a spring-damper (k=220, c=18),
  which produces the "breathing" button look.

  ==============================================================================
  LAYOUT MASK AND ALPHA FIX
  ==============================================================================

  GDI (FillRect, DrawText) works with 24-bit RGB and ignores alpha. A
  rectangle painted via GDI ALWAYS has alpha=255 in every pixel - even
  in the black background. For particle binding we want only the
  ACTUALLY PAINTED pixels to count as opaque, otherwise every particle
  would be bound to some random background pixel.

  The alpha fix in RebuildLayoutMaskIfNeeded() solves this:
    - Pure black (0x000000) in the DIB -> alpha=0 (background).
    - Everything else                  -> alpha=255 (control pixel).

  This gives the mask a real "painted / not painted" semantic.

  Label vs. button:
  -----------------
  Buttons FILL their rectangle with their color -> every pixel becomes
  opaque -> a dense particle rectangle.

  Labels paint ONLY the text (white) on a black background. The alpha
  fix then marks only the white text pixels as opaque, the black rest
  becomes background. Result: the label is a pure text silhouette made
  of particles, not a filled rectangle.

  ==============================================================================
  BGRA -> RGBA COLOR CONVERSION
  ==============================================================================

  The GDI DIB is BGRA (byte 0 = blue, byte 1 = green, byte 2 = red,
  byte 3 = alpha). The SSBO format is 0xRRGGBBAA (byte 0 = red in bits
  16..23, byte 1 = green in bits 8..15, byte 2 = blue in bits 0..7,
  byte 3 = alpha in bits 24..31). The reassign step must therefore swap
  them - otherwise red and blue end up swapped on screen (blue buttons
  become red and vice versa).

  ==============================================================================
  RENDERING TUNING (the anti-white-out knob)
  ==============================================================================

  Additive particle rendering saturates to pure white within a few
  frames at 800k particles unless three knobs work together:

    1. Ambient particle alpha is small (0.14) so free-floating dust
       adds only a soft tint to the framebuffer. This is raised from
       the original 0.04 so the visual delta between uAmbientRatio =
       0.05 (little dust) and 0.45 (much dust) is immediately obvious
       when "Toggle Dust" is clicked.
    2. Bound particle alpha stays at 1.0 and is written via a DIRECT
       imageStore (no imageLoad) so buttons and text keep full contrast
       AND dense buttons no longer hit the Read-Modify-Write cache stall
       that capped the old RMW path.
    3. The decay pass clamps the framebuffer at 0.85 brightness, so even
       a dense cloud of particles can never completely white out the
       background.

  If the whole surface starts looking too bright, lower FTrailPersistence
  (0.72 is a good default; 0.65 gives an even darker look).

  ==============================================================================
  HALF-RESOLUTION SIMULATION (fullscreen speed boost)
  ==============================================================================

  Oriented on uSkiaGPULiquid: when the on-screen client exceeds
  FULLSCREEN_VIEW_W x FULLSCREEN_VIEW_H (1100 x 750), the whole
  simulation drops to (ViewW div 2) x (ViewH div 2). The output
  texture, both PBOs, the layout mask, the DIB and the active
  particle count all track FSimWidth / FSimHeight, so:

    - PBO DMA bandwidth         -> quartered
    - Decay pass work           -> quartered
    - Particle dispatch work    -> quartered (TotalSimPixels * 2)
    - Layout-mask rebuild cost  -> quartered

  The finished sim-resolution GPU image is upscaled to (ViewW, ViewH)
  via TSkSamplingOptions.Medium in RenderEffect, so the controls stay
  100 % densely filled (one bound particle per opaque mask pixel) while
  the GPU only does a quarter of the work. Below the fullscreen
  threshold everything runs 1:1 so windowed mode keeps full sharpness.

  Mouse / hover / click coordinates are stored in VIEW pixels by the UI
  thread and scaled view->sim in ApplyMouseStateUniforms so the shader's
  uMousePos / uResolution still yields the correct UV in both modes.

  ==============================================================================
  AMBIENT BUDGET GATE (Toggle Dust without CPU lag)
  ==============================================================================

  The SSBO uses a FIXED layout: ambient dust occupies the first
  MAX_AMBIENT_RATIO (0.5) fraction of the particle array, bound mask
  particles the second half. FAmbientDensity is forwarded every frame
  as the uAmbientRatio uniform; in the shader, ambient particles whose
  idx/uParticleCount exceeds uAmbientRatio return immediately (neither
  simulated nor drawn).

  Consequence: toggling AmbientDensity changes a single float uniform
  and never rebuilds the layout mask or re-uploads the SSBO. The old
  per-toggle CPU stall (GDI repaint + alpha fix + 800k particle
  reassign + 25 MB glBufferData) is gone - "Toggle Dust" now reacts
  in real time with zero frame drop.

  ==============================================================================
  AUTHOR
  ==============================================================================
  Lara Miriam Tamy Reschke / LaMitaOne
  Based on uSkiaGPULiquid and uGPUParticlePageControl.
  State: working proof of concept with particle buttons, particle text
  labels, mouse interaction, click shockwave and hover magnet.
*******************************************************************************}

{$IFDEF FPC}{$mode objfpc}{$H+}{$ENDIF}

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.SyncObjs,
  System.UITypes, Winapi.Windows, Winapi.Messages, FMX.Types, FMX.Controls,
  FMX.Graphics, FMX.Forms, FMX.Objects, FMX.Platform.Win, System.Skia, FMX.Skia,
  uSkiaCustomThreadedBase;

const
  PFD_DOUBLEBUFFER = $00000001;
  PFD_SUPPORT_OPENGL = $00000020;
  PFD_DRAW_TO_WINDOW = $00000004;
  PFD_TYPE_RGBA = 0;
  WGL_CONTEXT_MAJOR_VERSION_ARB = $2091;
  WGL_CONTEXT_MINOR_VERSION_ARB = $2092;
  WGL_CONTEXT_FLAGS_ARB = $2094;
  WGL_CONTEXT_PROFILE_MASK_ARB = $9126;
  WGL_CONTEXT_CORE_PROFILE_BIT = $00000001;
  GL_COMPUTE_SHADER = $91B9;
  GL_ARRAY_BUFFER = $8892;
  GL_SHADER_STORAGE_BUFFER = $90D2;
  GL_SHADER_STORAGE_BARRIER_BIT = $00002000;
  GL_SHADER_IMAGE_ACCESS_BARRIER_BIT = $00000020;
  GL_TEXTURE_FETCH_BARRIER_BIT = $00000008;
  GL_TEXTURE_2D = $0DE1;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_TEXTURE_WRAP_S = $2802;
  GL_TEXTURE_WRAP_T = $2803;
  GL_NEAREST = $2600;
  GL_LINEAR = $2601;
  GL_CLAMP_TO_EDGE = $812F;
  GL_RGBA8 = $8058;
  GL_RED_INTEGER = $8D94;
  GL_R32UI = $8234;
  GL_UNSIGNED_INT = $1405;
  GL_UNSIGNED_BYTE = $1401;
  GL_BGRA = $80E1;
  GL_RGBA = $1908;
  GL_COMPILE_STATUS = $8B81;
  GL_LINK_STATUS = $8B82;
  GL_INFO_LOG_LENGTH = $8B84;
  GL_READ_WRITE = $88BA;
  GL_PIXEL_PACK_BUFFER = $88EB;
  GL_STREAM_READ = $88E1;
  GL_MAP_READ_BIT = $0001;
  GL_DYNAMIC_COPY = $88EA;

  { High-density particle cap: the active particle count is
    TotalSimPixels * 2 (2 particles per sim pixel for a lush, fine look),
    capped at PARTICLE_MAX. 2 M is enough to keep every control 100 %
    densely filled even at full 1:1 fullscreen (1920x1080 = 2.07 M px * 2,
    capped at 2 M) while the 2x2 splat means each bound body particle covers
    4 texels. SLOT_CAPACITY = 120000 so even a 180x180 PNG (32400 px) or a
    large high-res button fills 100 % with massive headroom. }
  PARTICLE_MAX = 2000000;

  { Despawn fade duration in seconds. RemoveParticleControl marks the control
    as despawning; the shader lets its bound particles drift apart and fade
    from alpha 1.0 to 0.0 over this window, then the control is removed and
    a full reassign reclaims the particles. }
  DESPAWN_DURATION = 0.45;

  { Fixed SSBO layout ratio: ambient dust occupies the first
    MAX_AMBIENT_RATIO fraction of the particle array, bound particle SLOTS
    the rest. 0.35 leaves 65 % for bound slots (each control gets a fixed
    SLOT_CAPACITY block) so up to ~11 independent controls fit. The
    uAmbientRatio uniform then controls at runtime what fraction of the
    ambient pool is actually simulated, so toggling AmbientDensity no
    longer requires a mask rebuild + SSBO re-upload (no CPU lag). }
  MAX_AMBIENT_RATIO = 0.35;

  { Per-control bound-particle slot capacity. Every control owns a fixed,
    non-overlapping block of this many particles in the SSBO. This is what
    isolates controls: a morph / spawn / despawn of one control touches ONLY
    its own slot [SlotStart .. SlotStart+SLOT_CAPACITY), so no particle ever
    flies between a label, a button and a PNG again. 120000 fits a 300x64
    label (19200 px), a 300x56 button (~16800 px) AND a 180x180 PNG (32400 px)
    - or a large high-res button - all at 100 % density with huge headroom. }
  SLOT_CAPACITY = 120000;

  { View-size threshold above which the simulation scales down (to
    SimResolutionScale, default 0.75). Below this (windowed mode) we render
    1:1 for full sharpness so text stays crisp; above it (big fullscreen
    windows >= 1600x1000) we scale to Round(ViewW*0.75) to keep the particle
    count manageable on an iGPU while staying sharp enough for legible text. }
  FULLSCREEN_VIEW_W = 1600;
  FULLSCREEN_VIEW_H = 1000;

type
  PFNGLCREATESHADERPROC = function(shaderType: Cardinal): Cardinal; stdcall;

  PFNGLDELETESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLSHADERSOURCEPROC = procedure(shader: Cardinal; count: Integer; str: PPAnsiChar; len: PInteger); stdcall;

  PFNGLCOMPILESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLGETSHADERIVPROC = procedure(shader: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLGETSHADERINFOLOGPROC = procedure(shader: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;

  PFNGLCREATEPROGRAMPROC = function: Cardinal; stdcall;

  PFNGLATTACHSHADERPROC = procedure(programObj: Cardinal; shader: Cardinal); stdcall;

  PFNGLLINKPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLDELETEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLGETPROGRAMIVPROC = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLGETPROGRAMINFOLOGPROC = procedure(programObj: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;

  PFNGLUSEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLGETUNIFORMLOCATIONPROC = function(programObj: Cardinal; name: PAnsiChar): Integer; stdcall;

  PFNGLUNIFORM1FPROC = procedure(location: Integer; v: Single); stdcall;

  PFNGLUNIFORM2FPROC = procedure(location: Integer; x: Single; y: Single); stdcall;

  PFNGLUNIFORM4FPROC = procedure(location: Integer; x, y, z, w: Single); stdcall;

  PFNGLUNIFORM1IPROC = procedure(location: Integer; v: Integer); stdcall;

  PFNGLUNIFORM1UIPROC = procedure(location: Integer; v: Cardinal); stdcall;

  PFNGLDISPATCHCOMPUTEPROC = procedure(num_groups_x, num_groups_y, num_groups_z: Cardinal); stdcall;

  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;

  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLDELETEBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;

  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;

  PFNGLBUFFERSUBDATAPROC = procedure(target: Cardinal; offset: NativeInt; size: NativeInt; data: Pointer); stdcall;

  PFNGLBINDBUFFERBASEPROC = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;

  PFNGLMAPBUFFERRANGEPROC = function(target: Cardinal; offset: NativeInt; length: NativeInt; access: Cardinal): Pointer; stdcall;

  PFNGLUNMAPBUFFERPROC = function(target: Cardinal): ByteBool; stdcall;

  PFNGLGENTEXTURESPROC = procedure(n: Integer; textures: PCardinal); stdcall;

  PFNGLDELETETEXTURESPROC = procedure(n: Integer; textures: PCardinal); stdcall;

  PFNGLBINDTEXTUREPROC = procedure(target: Cardinal; texture: Cardinal); stdcall;

  PFNGLTEXPARAMETERIPROC = procedure(target: Cardinal; pname: Cardinal; param: Integer); stdcall;

  PFNGLTEXSTORAGE2DPROC = procedure(target: Cardinal; levels: Integer; internalformat: Cardinal; width, height: Integer); stdcall;

  PFNGLACTIVETEXTUREPROC = procedure(texture: Cardinal); stdcall;

  PFNGLBINDIMAGETEXTUREPROC = procedure(unit_: Cardinal; texture: Cardinal; level: Integer; layered: Cardinal; layer: Integer; access: Cardinal; format: Cardinal); stdcall;

  PFNGLCLEARBUFFERDATAPROC = procedure(target: Cardinal; internalformat: Cardinal; format: Cardinal; type_: Cardinal; data: Pointer); stdcall;

  PFNGLGETTEXIMAGEPROC = procedure(target: Cardinal; level: Integer; format: Cardinal; type_: Cardinal; pixels: Pointer); stdcall;

  PFNWGLCREATECONTEXTATTRIBSARBPROC = function(hdc: HDC; shareContext: HGLRC; const attribList: PInteger): HGLRC; stdcall;

function wglCreateContext(hdc: HDC): HGLRC; stdcall; external 'opengl32.dll';

function wglDeleteContext(hglrc: HGLRC): BOOL; stdcall; external 'opengl32.dll';

function wglMakeCurrent(hdc: HDC; hglrc: HGLRC): BOOL; stdcall; external 'opengl32.dll';

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';

type
  TParticleControlType = (pctLabel, pctButton, pctPNG, pctEdit);

  TParticleClickEvent = procedure(Sender: TObject) of object;

  { Extensible effect-type enums. Each is forwarded to the particle shader
    (or the CPU slot reassign) as an int mode so new modes can be added by
    simply appending another ordinal + a matching branch - no signature
    changes anywhere. }

  { Background ambient behaviour (uBgMode): 0 = gentle sin/cos flow field,
    1 = soft central vortex, 2 = slow rising embers, 3 = background off. }
  TParticleBackgroundEffect = (pbeFlowField, pbeVortex, pbeEmbers, pbeNone);

  { Spawn formation (RenderAndAssignSlot spawn branch): 0 = scatter from
    centre swarm, 1 = implode from far, 2 = rise up from below, 3 = instant
    at home. }
  TParticleSpawnEffect = (pseSwarmIn, pseImplode, pseRiseUp, pseInstant);

  { Despawn dissolution (uDespawnMode): 0 = explode outward, 1 = dissolve up,
    2 = vortex suck inward, 3 = instant fade. }
  TParticleDespawnEffect = (pdeExplodeOut, pdeDissolveUp, pdeVortexSuck, pdeInstant);

  { Morph transition (RenderAndAssignSlot morph branch): 0 = cloud reform
    (explode + reassemble), 1 = scatter then snap, 2 = wave sweep, 3 =
    instant change. }
  TParticleMorphEffect = (pmeCloudReform, pmeScatterSnap, pmeWaveSweep, pmeInstant);

  { Visual UI style (uUIStyle): 0 = pusSolidFluid (the current standard look,
    dense 2x2 body splat + crisp 1x1 text, unchanged), 1 = pusHolographic
    (sci-fi hologram - only every 2nd bound particle, 1x1 dot, scanline wave,
    cool cyan/neon shimmer). Forwarded to the particle compute shader as the
    int uniform uUIStyle every frame, so switching is instant with no mask
    rebuild / SSBO re-upload. }
  TParticleUIStyle = (pusSolidFluid, pusHolographic);

  { One virtual control in the particle UI. Kept on the UI thread; the
    render thread only reads the composited BGRA mask plus per-control
    hover/visible state. }
  TParticleControl = record
    Name: string;
    CtlType: TParticleControlType;
    Bounds: TRect;             // window pixels, top-left origin
    Text: string;
    Color: Cardinal;           // packed 0xAARRGGBB (FMX TAlphaColor layout)
    OnClick: TParticleClickEvent;
    OnChange: TNotifyEvent;    // for pctEdit: fired by HandleKeyInput after each keystroke
    BGRA: TBytes;              // for pctPNG: decoded BGRA bytes (ImgW*ImgH*4)
    ImgW: Integer;
    ImgH: Integer;
    Hovered: Boolean;
    Visible: Boolean;
    // Per-control morph request (replaces the old single global FMorphControlIdx
    // + FMorphGentle). Set by HandleKeyInput (typing / backspace), UpdateControlText
    // (caption change), focus moves (MouseDown) and SetControlVisible.
    // RebuildLayoutMaskIfNeeded loops over ALL controls every frame and renders
    // + uploads every flagged one in the SAME frame - so a keystroke in the
    // edit AND the mirrored label OnChange both rebuild together, instead of
    // the label's request overwriting the edit's (the FMorphControlIdx race).
    // ExplodeOnRebuild = AExplode passed to RenderAndAssignSlot: True = cloud
    // reform (button caption morph), False = gentle retarget (typing /
    // backspace / caret). Protected by FControlsLock.
    NeedsRebuild: Boolean;
    ExplodeOnRebuild: Boolean;
    // Slot isolation: every control owns a fixed, non-overlapping block of
    // SLOT_CAPACITY particles starting at SlotStart in the SSBO. A morph /
    // spawn / despawn of ONE control touches ONLY its own slot, so no
    // particle ever flies between a label, a button and a PNG. SlotStart is
    // deterministic: FBoundStart + ControlIndex * SLOT_CAPACITY (set during
    // the full rebuild, stable until the control count changes).
    SlotStart: Cardinal;
    SlotCapacity: Cardinal;
    // Despawn: when RemoveParticleControl is called the control is not
    // deleted immediately - Despawning=True + DespawnTimer=DESPAWN_DURATION
    // tell the shader (via uDespawnRect / uDespawnFade) to let this
    // control's bound particles lose their spring, drift apart and fade.
    // When the timer hits 0 the control is removed for real.
    Despawning: Boolean;
    DespawnTimer: Single;
  end;

  TGPUAliveComponentHost = class(TSkiaCustomThreadedBase)
  private
    { Dummy window + GL context (created and owned by the render thread) }
    FDummyWnd: HWND;
    FDummyDC: HDC;
    FGLContext: HGLRC;
    FGLReady: Boolean;
    FGLFailed: Boolean;
    FErrorMsg: string;

    { GL resources }
    FOutputTex: Cardinal;
    FParticleSSBO: Cardinal;
    FParticleCount: Cardinal;       // active particles simulated this frame
    FMaxParticles: Cardinal;        // SSBO capacity (pre-allocated once)
    FTexWidth: Integer;             // actual GL texture size (== FSimWidth)
    FTexHeight: Integer;            // actual GL texture size (== FSimHeight)

    { Half-resolution simulation (oriented on uSkiaGPULiquid). FView* is the
      on-screen client size; FSim* is the resolution the compute shaders,
      the output texture, the PBOs and the layout mask run at. In fullscreen
      FSim = FView div 2, which quarters PBO DMA, the decay pass and the
      particle dispatch. The finished GPUImg is upscaled to (ViewW, ViewH)
      via TSkSamplingOptions.Medium in RenderEffect. }
    FViewWidth: Integer;
    FViewHeight: Integer;
    FSimWidth: Integer;
    FSimHeight: Integer;

    { CPU-side mirror of the SSBO (32 bytes per particle) so the UI
      thread can build the layout mask and the render thread can reassign
      bound particles without map/unmap churn. }
    FParticleCPU: TBytes;
    FBoundStart: Cardinal;
    FBoundCount: Cardinal;
    FAmbientCount: Cardinal;

    { Shader programs + uniform locations }
    FParticleProgram: Cardinal;
    FDecayProgram: Cardinal;
    FLocP_DeltaTime: Integer;
    FLocP_Resolution: Integer;
    FLocP_MousePos: Integer;
    FLocP_MouseVel: Integer;
    FLocP_ClickPulse: Integer;
    FLocP_ClickPos: Integer;
    FLocP_HoverRect: Integer;
    FLocP_HoverGlow: Integer;
    FLocP_FocusRect: Integer;      // uFocusRect: sim-space rect of the focused pctEdit (-1 = none)
    FLocP_FocusGlow: Integer;      // uFocusGlow: subtle rim brightness for the focused edit
    FLocP_CursorRect: Integer;     // uCursorRect: sim-space caret strip of the focused edit (-1 = off-phase / none)
    FLocP_CursorBlink: Integer;    // uCursorBlink: smooth 0..1 caret glow envelope (0.5 s blink)
    FLocP_UIStyle: Integer;        // uUIStyle: visual style (0=SolidFluid, 1=Holographic)
    FLocP_ParticleCount: Integer;
    FLocP_Time: Integer;
    FLocP_AmbientRatio: Integer;
    FLocP_BtnClickFlash: Integer;     // uBtnClickFlash: decaying edge flash on clicked button
    FLocP_DespawnRect: Integer;       // uDespawnRect: sim-space rect of the despawning control
    FLocP_DespawnFade: Integer;       // uDespawnFade: 1.0 -> 0.0 over DESPAWN_DURATION
    FLocP_SpringK: Integer;           // uSpringK: bound particle spring stiffness
    FLocP_MouseForce: Integer;        // uMouseForce: fluid mouse swirl strength
    FLocP_BgMode: Integer;            // uBgMode: background effect mode (0-3)
    FLocP_DespawnMode: Integer;       // uDespawnMode: despawn effect mode (0-3)
    FLocD_Resolution: Integer;
    FLocD_DecayFactor: Integer;

    { GL function pointers (loaded once in LoadGLFunctions) }
    glCreateShader: PFNGLCREATESHADERPROC;
    glDeleteShader: PFNGLDELETESHADERPROC;
    glShaderSource: PFNGLSHADERSOURCEPROC;
    glCompileShader: PFNGLCOMPILESHADERPROC;
    glGetShaderiv: PFNGLGETSHADERIVPROC;
    glGetShaderInfoLog: PFNGLGETSHADERINFOLOGPROC;
    glCreateProgram: PFNGLCREATEPROGRAMPROC;
    glAttachShader: PFNGLATTACHSHADERPROC;
    glLinkProgram: PFNGLLINKPROGRAMPROC;
    glDeleteProgram: PFNGLDELETEPROGRAMPROC;
    glGetProgramiv: PFNGLGETPROGRAMIVPROC;
    glGetProgramInfoLog: PFNGLGETPROGRAMINFOLOGPROC;
    glUseProgram: PFNGLUSEPROGRAMPROC;
    glGetUniformLocation: PFNGLGETUNIFORMLOCATIONPROC;
    glUniform1f: PFNGLUNIFORM1FPROC;
    glUniform2f: PFNGLUNIFORM2FPROC;
    glUniform4f: PFNGLUNIFORM4FPROC;
    glUniform1i: PFNGLUNIFORM1IPROC;
    glUniform1ui: PFNGLUNIFORM1UIPROC;
    glDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
    glMemoryBarrier: PFNGLMEMORYBARRIERPROC;
    glGenBuffers: PFNGLGENBUFFERSPROC;
    glDeleteBuffers: PFNGLDELETEBUFFERSPROC;
    glBindBuffer: PFNGLBINDBUFFERPROC;
    glBufferData: PFNGLBUFFERDATAPROC;
    glBufferSubData: PFNGLBUFFERSUBDATAPROC;
    glBindBufferBase: PFNGLBINDBUFFERBASEPROC;
    glMapBufferRange: PFNGLMAPBUFFERRANGEPROC;
    glUnmapBuffer: PFNGLUNMAPBUFFERPROC;
    glGenTextures: PFNGLGENTEXTURESPROC;
    glDeleteTextures: PFNGLDELETETEXTURESPROC;
    glBindTexture: PFNGLBINDTEXTUREPROC;
    glTexParameteri: PFNGLTEXPARAMETERIPROC;
    glTexStorage2D: PFNGLTEXSTORAGE2DPROC;
    glActiveTexture: PFNGLACTIVETEXTUREPROC;
    glBindImageTexture: PFNGLBINDIMAGETEXTUREPROC;
    glClearBufferData: PFNGLCLEARBUFFERDATAPROC;
    glGetTexImage: PFNGLGETTEXIMAGEPROC;
    wglCreateContextAttribsARB: PFNWGLCREATECONTEXTATTRIBSARBPROC;

    { PBO ping-pong for async glGetTexImage (GPU->RAM transfer overlaps
      with the next frame's compute work; removes the pipeline stall). }
    FPBOs: array[0..1] of Cardinal;
    FPBOSize: NativeInt;
    FPBOIndex: Integer;
    FPBOHasData: Boolean;

    { CPU-side pixel buffer that RenderEffect hands to Skia }
    FPixelBuffer: TBytes;

    { Resize flag (UI thread writes, render thread consumes) }
    FResizePending: Boolean;
    FGLLock: TCriticalSection;

    { Mouse / click state (UI thread writes, render thread reads under
      FMouseLock) }
    FMouseLock: TCriticalSection;
    FMouseX: Single;
    FMouseY: Single;
    FMouseDX: Single;
    FMouseDY: Single;
    FClickPulse: Single;
    FClickX: Single;
    FClickY: Single;
    FHoveredIndex: Integer;
    // FBtnClickFlash: decaying 1.0 -> 0.0 pulse set when a BUTTON is clicked.
    // Drives the uBtnClickFlash uniform so the button's edge particles flash
    // bright briefly without a global shockwave. Protected by FMouseLock.
    FBtnClickFlash: Single;
    // pctEdit focus + blinking caret. FFocusedIndex is the index into FControls
    // of the currently focused edit (-1 = none). Set by MouseDown (UI thread)
    // when an edit is clicked, cleared when anything else is clicked. The render
    // thread ticks FCursorBlinkAccum; every 0.5 s it toggles FCursorOnPhase and,
    // if an edit is focused, triggers a GENTLE morph so the '|' caret (appended
    // to the text in RenderControlToCanvas) appears/disappears as real particles.
    // FFocusedIndex / FCursorOnPhase are written under FMouseLock; the render
    // thread reads them lock-free in RenderControlToCanvas (aligned int / 1-byte
    // bool = no torn read on x86/x64; a one-frame-stale caret is harmless).
    FFocusedIndex: Integer;
    FCursorBlinkAccum: Single;
    FCursorOnPhase: Boolean;
    // Despawn: only one control despawns at a time. FDespawnControlIdx is the
    // index into FControls (-1 = none). The render thread ticks FDespawnTimer
    // down each frame; when it hits 0 the control is removed and a full
    // reassign reclaims the particles. Protected by FControlsLock.
    FDespawnControlIdx: Integer;
    FDespawnTimer: Single;

    { Virtual controls (UI thread owns the list, render thread reads via
      FControlsLock) }
    FControls: array of TParticleControl;
    FControlsLock: TCriticalSection;

    { Layout mask (BGRA, FTexWidth * FTexHeight * 4) }
    FLayoutMask: TBytes;
    FLayoutDirty: Boolean;
    // FSpawnControlIdx: set by AddParticleButton/Label/PNG to the index of
    // the newly added control. RebuildLayoutMaskIfNeeded then calls
    // RenderAndAssignSlot(FSpawnControlIdx, spawn=True) which scatters the
    // new control's bound particles around its centre (swarm formation) and
    // uploads ONLY that slot. -1 = no spawn pending.
    FSpawnControlIdx: Integer;
    FLayoutMaskLock: TCriticalSection;

    { Offscreen Win32 DIB used to rasterize virtual controls into the
      BGRA mask via pure GDI (no FMX canvas in the render thread). }
    FDIB: HBITMAP;
    FDIBDC: HDC;
    FDIBBits: Pointer;
    FDIBInfo: TBitmapInfo;

    { Configuration }
    FAmbientDensity: Single;
    FTrailPersistence: Single;
    { Live-tunable effect parameters (all forwarded to the particle shader
      as uniforms every frame, so changing them at runtime needs no mask
      rebuild or SSBO re-upload - zero stutter). }
    FSpringStiffness: Single;     // -> uSpringK (bound particle spring force)
    FHoverGlowStrength: Single;   // -> uHoverGlow when a button is hovered
    FMouseRepelForce: Single;     // -> uMouseForce (fluid swirl strength)
    FSimResolutionScale: Single;  // fullscreen sim downscale (0.75 default)
    FBackgroundEffect: TParticleBackgroundEffect;  // -> uBgMode
    FSpawnEffect: TParticleSpawnEffect;            // CPU spawn branch
    FDespawnEffect: TParticleDespawnEffect;        // -> uDespawnMode
    FMorphEffect: TParticleMorphEffect;            // CPU morph branch
    FUIStyle: TParticleUIStyle;                     // -> uUIStyle (visual style)

    { Internal methods - GL setup (render thread only) }
    function InitOffscreenGL: Boolean;
    procedure CleanupOffscreenGL;
    procedure LoadGLFunctions;
    function CompileShader(AShaderType: Cardinal; const ASrc: AnsiString): Cardinal;
    function LinkProgram(const AShaders: array of Cardinal): Cardinal;
    procedure InitShaders;
    procedure InitGLResources;
    procedure ResizeTextures(NewW, NewH: Integer);
    procedure UploadSSBO;
    { UploadSlot: partial glBufferSubData upload of a single control's slot
      [SlotStart .. SlotStart+SlotCap). Used by morph / spawn / despawn so
      only the affected control's particles are refreshed on the GPU -
      every other slot and the ambient pool stay untouched. }
    procedure UploadSlot(SlotStart, SlotCap: Cardinal);

    { Compute FSimWidth/FSimHeight from the current view size. Called every
      frame from RenderEffect (and once from InitOffscreenGL) so the
      resolution scaling tracks the live window size. }
    procedure UpdateSimResolution(ViewW, ViewH: Integer);

    { Render-thread work }
    procedure DispatchComputeFrame(DeltaTime, TimeSec: Double);
    procedure DispatchDecayPass;
    procedure ApplyMouseStateUniforms;

    { Layout mask }
    procedure RebuildLayoutMaskIfNeeded;
    procedure RenderControlToCanvas(const ACtl: TParticleControl; AIndex: Integer);
    procedure MarkLayoutDirty;
    { FixAlphaMask: walks the GDI DIB and marks every non-pure-black pixel
      opaque (alpha = $FF) and every pure-black pixel transparent, then copies
      the result into FLayoutMask. Called AFTER the caller has cleared the
      DIB to black and painted control(s) into it. This turns labels into
      pure text silhouettes (black rect + white text -> only text survives)
      and keeps buttons fully opaque. For PNGs (AIsPNG=True) the gate uses the
      SOURCE alpha channel (preserved by StretchDIBits' SRCCOPY) with a low
      threshold of 4 (plus a non-black fallback) so faint anti-aliased edges /
      glows AND pure-black-but-opaque logo pixels survive instead of being
      dropped by the pure-black RGB check. }
    procedure FixAlphaMask(AIsPNG: Boolean = False);

    { Particle reassignment }
    { ReassignParticlesFromMask: FULL rebuild - paints every visible control
      to the DIB, assigns each to its own fixed slot [SlotStart ..
      SlotStart+SLOT_CAPACITY), reseeds ambient and uploads the whole active
      prefix. Called on resize / initial load / despawn completion. }
    procedure ReassignParticlesFromMask;
    { RenderAndAssignSlot: paints ONLY the control at AIndex to the DIB,
      scans it and assigns its opaque pixels to the control's fixed slot.
      AMorph=True preserves existing positions + kicks an explosion impulse
      (letters scatter then reassemble). ASpawn=True scatters particles
      around the control centre (swarm formation). Otherwise pos = home.
      AExplode=False (used by HandleKeyInput + the caret blink) switches the
      morph branch to a GENTLE retarget: existing bound particles keep their
      position and glide to the new home via the spring (no scatter impulse),
      and surplus particles drift out softly instead of blasting apart - so
      each keystroke reflows an edit smoothly instead of exploding it.
      Does NOT upload - caller uploads via UploadSlot. }
    procedure RenderAndAssignSlot(AIndex: Integer; AMorph: Boolean; ASpawn: Boolean; AExplode: Boolean = True);
    procedure SeedAmbientParticles(StartIdx, EndIdx: Integer);

    { Controls }
    function FindControlByName(const AName: string): Integer;
    { CompleteDespawnInternal: removes FControls[FDespawnControlIdx] from the
      array (shifting successors) and resets the despawn slot. Caller MUST
      hold FControlsLock and call MarkLayoutDirty afterwards (outside the
      lock to respect lock ordering with FLayoutMaskLock). }
    procedure CompleteDespawnInternal;
    { TickDespawn: called from RenderEffect each frame to count down the
      active despawn timer and complete the removal when it elapses. }
    procedure TickDespawn(DeltaTime: Double);

    { Setters }
    procedure SetAmbientDensity(const Value: Single);
    procedure SetTrailPersistence(const Value: Single);
  protected
    procedure UpdateLogic(const DeltaTime: Double); override;
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double); override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure DoMouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { One-time start: just sets Active := True. The GL setup happens
      lazily in RenderEffect on the render thread. Call this from the UI
      thread after the control has been parented. }
    procedure InitGL;

    { Virtual control management (UI thread only). Returns the index of
      the added control, or -1 on failure. }
    function AddParticleLabel(const AName: string; X, Y, W, H: Integer; const AText: string; AColor: Cardinal): Integer;
    function AddParticleButton(const AName: string; X, Y, W, H: Integer; const AText: string; AColor: Cardinal; AOnClick: TParticleClickEvent): Integer;
    function AddParticlePNG(const AName: string; X, Y, W, H: Integer; const ABGRABytes: TBytes; ImgW, ImgH: Integer): Integer;
    { AddParticleEdit: a particle input field. Drawn as a dark rounded rect
      with a fine lighter border + left-aligned text; when focused it shows a
      blinking '|' caret made of real particles. AOnChange fires after every
      keystroke handled by HandleKeyInput. AColor is the dark fill (0xAARRGGBB). }
    function AddParticleEdit(const AName, AInitialText: string; X, Y, W, H: Integer; AColor: TAlphaColor; AOnChange: TNotifyEvent = nil): Integer;
    procedure UpdateControlText(const AName, ANewText: string; AGentle: Boolean = False);
    procedure SetControlVisible(const AName: string; AVisible: Boolean);
    { RemoveParticleControl: marks the control at AIndex as despawning - its
      bound particles lose their spring, drift apart and fade over
      DESPAWN_DURATION seconds, then the control is removed for real. Safe
      to call from the UI thread. }
    procedure RemoveParticleControl(AIndex: Integer);

    { HandleKeyInput: route a keystroke to the focused pctEdit. vkBack (Key=8)
      deletes the last char; a printable KeyChar (>= #32) is appended. Then the
      edit's slot is gently re-masked (AExplode=False, no explosion) and the
      edit's OnChange fires. Call this from the host form's KeyDown handler
      when an edit is focused. No-op if no edit is focused. }
    procedure HandleKeyInput(var Key: Word; var KeyChar: WideChar);

    { Read-only enumeration for external UIs (e.g. a sandbox list box). }
    function GetControlCount: Integer;
    function GetControlDisplay(AIndex: Integer): string;
    { GetControlText: current caption / text of the named control. Used by
      pctEdit OnChange handlers (e.g. the demo mirrors the edit text into the
      big label) to read what the user just typed. }
    function GetControlText(const AName: string): string;

    function HitTestButton(X, Y: Integer): Integer;
    { HitTestEditable: returns the index of the topmost visible pctEdit whose
      bounds contain (X,Y), or -1. Used by MouseDown to set the caret focus. }
    function HitTestEditable(X, Y: Integer): Integer;

    property AmbientDensity: Single read FAmbientDensity write SetAmbientDensity;
    property TrailPersistence: Single read FTrailPersistence write SetTrailPersistence;
    { Live-tunable parameters. All forwarded to the shader as uniforms every
      frame (or read by UpdateSimResolution / RenderAndAssignSlot), so changing
      them at runtime is instant with no mask rebuild or SSBO re-upload. }
    property SpringStiffness: Single read FSpringStiffness write FSpringStiffness;
    property HoverGlowStrength: Single read FHoverGlowStrength write FHoverGlowStrength;
    property MouseRepelForce: Single read FMouseRepelForce write FMouseRepelForce;
    property SimResolutionScale: Single read FSimResolutionScale write FSimResolutionScale;
    property BackgroundEffect: TParticleBackgroundEffect read FBackgroundEffect write FBackgroundEffect;
    property SpawnEffect: TParticleSpawnEffect read FSpawnEffect write FSpawnEffect;
    property DespawnEffect: TParticleDespawnEffect read FDespawnEffect write FDespawnEffect;
    property MorphEffect: TParticleMorphEffect read FMorphEffect write FMorphEffect;
    property UIStyle: TParticleUIStyle read FUIStyle write FUIStyle;
  end;

implementation

{==============================================================================
  GL function loading
==============================================================================}

procedure TGPUAliveComponentHost.LoadGLFunctions;

  function GetProc(const Name: AnsiString): Pointer;
  begin
    Result := wglGetProcAddress(PAnsiChar(Name));
    if (Result = nil) or (Result = Pointer(1)) or (Result = Pointer(2)) or (Result = Pointer(3)) or (Result = Pointer(-1)) then
      Result := GetProcAddress(GetModuleHandleA('opengl32.dll'), PAnsiChar(Name));
  end;

begin
  glCreateShader := GetProc('glCreateShader');
  glDeleteShader := GetProc('glDeleteShader');
  glShaderSource := GetProc('glShaderSource');
  glCompileShader := GetProc('glCompileShader');
  glGetShaderiv := GetProc('glGetShaderiv');
  glGetShaderInfoLog := GetProc('glGetShaderInfoLog');
  glCreateProgram := GetProc('glCreateProgram');
  glAttachShader := GetProc('glAttachShader');
  glLinkProgram := GetProc('glLinkProgram');
  glDeleteProgram := GetProc('glDeleteProgram');
  glGetProgramiv := GetProc('glGetProgramiv');
  glGetProgramInfoLog := GetProc('glGetProgramInfoLog');
  glUseProgram := GetProc('glUseProgram');
  glGetUniformLocation := GetProc('glGetUniformLocation');
  glUniform1f := GetProc('glUniform1f');
  glUniform2f := GetProc('glUniform2f');
  glUniform4f := GetProc('glUniform4f');
  glUniform1i := GetProc('glUniform1i');
  glUniform1ui := GetProc('glUniform1ui');
  glDispatchCompute := GetProc('glDispatchCompute');
  glMemoryBarrier := GetProc('glMemoryBarrier');
  glGenBuffers := GetProc('glGenBuffers');
  glDeleteBuffers := GetProc('glDeleteBuffers');
  glBindBuffer := GetProc('glBindBuffer');
  glBufferData := GetProc('glBufferData');
  glBufferSubData := GetProc('glBufferSubData');
  glBindBufferBase := GetProc('glBindBufferBase');
  glMapBufferRange := GetProc('glMapBufferRange');
  glUnmapBuffer := GetProc('glUnmapBuffer');
  glGenTextures := GetProc('glGenTextures');
  glDeleteTextures := GetProc('glDeleteTextures');
  glBindTexture := GetProc('glBindTexture');
  glTexParameteri := GetProc('glTexParameteri');
  glTexStorage2D := GetProc('glTexStorage2D');
  glActiveTexture := GetProc('glActiveTexture');
  glBindImageTexture := GetProc('glBindImageTexture');
  glClearBufferData := GetProc('glClearBufferData');
  glGetTexImage := GetProc('glGetTexImage');

  if not Assigned(glDispatchCompute) or not Assigned(glBindImageTexture) then
    raise Exception.Create('OpenGL 4.3 compute shaders not supported');
  if not Assigned(glMapBufferRange) or not Assigned(glUnmapBuffer) then
    raise Exception.Create('OpenGL PBO (glMapBufferRange) not supported');
  if not Assigned(glActiveTexture) then
    raise Exception.Create('glActiveTexture not supported');
  if not Assigned(glUniform1ui) then
    raise Exception.Create('glUniform1ui not supported');
  if not Assigned(glClearBufferData) then
    raise Exception.Create('glClearBufferData not supported');
  if not Assigned(glGetTexImage) then
    raise Exception.Create('glGetTexImage not supported');
end;

function TGPUAliveComponentHost.CompileShader(AShaderType: Cardinal; const ASrc: AnsiString): Cardinal;
var
  SrcArr: PPAnsiChar;
  Len: Integer;
  Status: Integer;
  LogLen: Integer;
  Log: AnsiString;
begin
  Result := 0;
  if not Assigned(glCreateShader) then
    Exit;
  Result := glCreateShader(AShaderType);
  if Result = 0 then
    Exit;
  SrcArr := PPAnsiChar(@ASrc[1]);
  Len := Length(ASrc);
  glShaderSource(Result, 1, @SrcArr, @Len);
  glCompileShader(Result);
  glGetShaderiv(Result, GL_COMPILE_STATUS, @Status);
  if Status = 0 then
  begin
    glGetShaderiv(Result, GL_INFO_LOG_LENGTH, @LogLen);
    SetLength(Log, LogLen);
    if LogLen > 0 then
      glGetShaderInfoLog(Result, LogLen, nil, PAnsiChar(Log));
    glDeleteShader(Result);
    raise Exception.Create('Shader compile error: ' + string(Log));
  end;
end;

function TGPUAliveComponentHost.LinkProgram(const AShaders: array of Cardinal): Cardinal;
var
  I: Integer;
  Status: Integer;
  LogLen: Integer;
  Log: AnsiString;
begin
  Result := glCreateProgram;
  if Result = 0 then
    Exit;
  for I := Low(AShaders) to High(AShaders) do
    glAttachShader(Result, AShaders[I]);
  glLinkProgram(Result);
  glGetProgramiv(Result, GL_LINK_STATUS, @Status);
  if Status = 0 then
  begin
    glGetProgramiv(Result, GL_INFO_LOG_LENGTH, @LogLen);
    SetLength(Log, LogLen);
    if LogLen > 0 then
      glGetProgramInfoLog(Result, LogLen, nil, PAnsiChar(Log));
    glDeleteProgram(Result);
    raise Exception.Create('Program link error: ' + string(Log));
  end;
  for I := Low(AShaders) to High(AShaders) do
    glDeleteShader(AShaders[I]);
end;

{==============================================================================
  Shader sources

  Particle shader:
  - Lazy seeding is NOT used here (unlike the Liquid) because the CPU
    already fills the SSBO with random positions and colors when the mask
    is (re)built. The shader only has to integrate physics and write.
  - Ambient particles (flags == 0) drift with sine noise, wrap around
    the edges, and are pushed away from the mouse.
  - Bound particles (flags == 1) are pulled to homePos by a spring-damper
    and receive a tiny per-particle flutter so the button "breathes".
  - The mouse acts as a tangential + radial force field whose strength
    falls off exponentially with distance.
  - A hovered button makes ambient dust swirl tangentially around its
    edge (a soft halo) and adds a narrow white edge-glow band to the
    button's own bound particles. No center magnet - the old one blew
    the button face out to white.
  - A click on the BACKGROUND pulses outward as an expanding ring
    shockwave (uClickPulse). A click on a BUTTON instead sets
    uBtnClickFlash (1.0 -> 0.0), which makes the button's edge particles
    flash bright briefly without disturbing the rest of the field.
  - Output is written into the image2D via imageLoad/imageStore.

  Decay shader:
  - Multiplies RGB by a per-frame trail factor, subtracts a small
    constant, and clamps the result at 0.85 so additive particle
    rendering can never fully white-out the background.
==============================================================================}
procedure TGPUAliveComponentHost.InitShaders;
const
  PARTICLE_SRC: AnsiString = '#version 430 core'#10 + 'layout(local_size_x = 256) in;'#10 + 'struct Particle {'#10 + '  vec2 pos;'#10 + '  vec2 vel;'#10 + '  vec2 homePos;'#10 + '  uint color;'#10 + '  uint flags;'#10 + '};'#10 + 'layout(binding = 0, std430) buffer ParticleSSBO {'#10 + '  Particle Particles[];'#10 + '};'#10 + 'layout(rgba8, binding = 0) uniform image2D uOutput;'#10 + 'uniform float uDeltaTime;'#10 + 'uniform float uTime;'#10 + 'uniform vec2  uResolution;'#10 + 'uniform vec2  uMousePos;'#10 +
    'uniform vec2  uMouseVel;'#10 + 'uniform vec4  uHoverRect;'#10 + 'uniform float uHoverGlow;'#10 + 'uniform vec4  uFocusRect;'#10 + 'uniform float uFocusGlow;'#10 + 'uniform float uClickPulse;'#10 + 'uniform vec2  uClickPos;'#10 + 'uniform uint  uParticleCount;'#10 + 'uniform float uAmbientRatio;'#10 + 'uniform float uBtnClickFlash;'#10 + 'uniform vec4  uDespawnRect;'#10 + 'uniform float uDespawnFade;'#10 + 'uniform float uSpringK;'#10 + 'uniform float uMouseForce;'#10 + 'uniform int   uBgMode;'#10 + 'uniform int   uDespawnMode;'#10 + 'uniform vec4  uCursorRect;'#10 + 'uniform float uCursorBlink;'#10 + 'uniform int   uUIStyle;'#10 + #10 + 'vec4 unpackCol(uint c){ return vec4(float((c>>16)&0xFF)/255.0, float((c>>8)&0xFF)/255.0, float(c&0xFF)/255.0, float((c>>24)&0xFF)/255.0); }'#10 + #10 + 'void main(){'#10 +
    // 2D dispatch index: the X axis alone caps at GL_MAX_COMPUTE_WORK_GROUP_COUNT
    // (65535). With local_size_x = 256 the Y axis still multiplies the
    // addressable space so even the 800k particle cap fits cleanly.
    '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 256u) + gl_GlobalInvocationID.x;'#10 + '  if (idx >= uParticleCount) return;'#10 + '  vec2 pos = Particles[idx].pos;'#10 + '  vec2 vel = Particles[idx].vel;'#10 + '  vec2 home = Particles[idx].homePos;'#10 + '  uint flags = Particles[idx].flags;'#10 + #10 + '  float dt = clamp(uDeltaTime, 0.0, 0.033);'#10 + #10 +
    // Ambient budget gate: the SSBO reserves its first MAX_AMBIENT_RATIO
    // fraction of slots for free-floating dust. Particles whose
    // idx/uParticleCount exceeds uAmbientRatio are neither simulated nor
    // drawn, so toggling AmbientDensity costs zero CPU (no mask rebuild,
    // no SSBO re-upload) - the uniform just shrinks the active ambient
    // pool in real time on the GPU.
    '  if (flags == 0u && (float(idx) / float(uParticleCount)) > uAmbientRatio) return;'#10 + #10 +
    // Despawn detection: a bound particle whose home is inside uDespawnRect
    // belongs to a control being removed (RemoveParticleControl). It loses
    // its spring, drifts outward from the control centre, and fades
    // (alpha = uDespawnFade in the write section below).
    '  bool despawning = false;'#10 + '  if (uDespawnRect.x >= 0.0 && flags > 0u) {'#10 + '    vec2 dpUV = uDespawnRect.xy / uResolution;'#10 + '    vec2 dpSize = uDespawnRect.zw / uResolution;'#10 + '    if (home.x >= dpUV.x && home.x <= dpUV.x + dpSize.x && home.y >= dpUV.y && home.y <= dpUV.y + dpSize.y) despawning = true;'#10 + '  }'#10 + #10 +
    // Physics: bound particles use a spring-damper toward homePos (uSpringK)
    // plus a gentle breathing wave so buttons / labels / PNGs feel alive; on
    // despawn they follow uDespawnMode (0 explode out, 1 dissolve up,
    // 2 vortex suck, 3 instant). Ambient particles follow uBgMode (0 flow
    // field, 1 vortex, 2 embers, 3 off) and wrap around edges.
    '  if (flags > 0u) {'#10 + '    if (despawning) {'#10 + '      vec2 dpUV = uDespawnRect.xy / uResolution;'#10 + '      vec2 dpSize = uDespawnRect.zw / uResolution;'#10 + '      vec2 dCenter = dpUV + dpSize * 0.5;'#10 + '      vec2 fromC = home - dCenter;'#10 + '      if (uDespawnMode == 0) {'#10 + '        vel += normalize(fromC + vec2(1e-5)) * 0.5 * dt;'#10 + '        vel *= 0.94;'#10 + '      } else if (uDespawnMode == 1) {'#10 + '        vel.y -= 0.4 * dt;'#10 + '        vel += vec2(sin(uTime*4.0 + float(idx)*0.3), 0.0) * 0.05;'#10 + '        vel *= 0.96;'#10 + '      } else if (uDespawnMode == 2) {'#10 + '        vec2 toC = normalize(-fromC + vec2(1e-5));'#10 + '        vec2 tang = vec2(-toC.y, toC.x);'#10 + '        vel += (toC * 0.3 + tang * 0.2) * dt;'#10 + '        vel *= 0.93;'#10 + '      } else {'#10 + '        vel *= 0.9;'#10 + '      }'#10 + '    } else {'#10 + '      vec2 d = home - pos;'#10 + '      float k = uSpringK;'#10 + '      float c = 18.0;'#10 + '      vel += d * k * dt - vel * c * dt;'#10 + '      float wob = (flags == 2u) ? 0.00018 : 0.00055;'#10 + '      vel += vec2(sin(uTime*2.8 + float(idx)*0.13), cos(uTime*2.2 + float(idx)*0.21)) * wob;'#10 + '    }'#10 + '  } else {'#10 + '    if (uBgMode == 0) {'#10 + '      vel += vec2(sin(uTime*0.6 + float(idx)*0.07), cos(uTime*0.5 + float(idx)*0.05)) * 0.0015;'#10 + '    } else if (uBgMode == 1) {'#10 + '      vec2 toC = vec2(0.5) - pos;'#10 + '      float dc = length(toC) + 1e-5;'#10 + '      vel += vec2(-toC.y, toC.x) / dc * 0.0012;'#10 + '      vel += toC / dc * 0.0003;'#10 + '    } else if (uBgMode == 2) {'#10 + '      vel.y -= 0.002;'#10 + '      vel += vec2(sin(uTime*1.5 + float(idx)*0.2), 0.0) * 0.0008;'#10 + '    } else {'#10 + '      vel += vec2(sin(uTime*0.3 + float(idx)*0.05), cos(uTime*0.25 + float(idx)*0.04)) * 0.0003;'#10 + '    }'#10 + '    vel *= 0.985;'#10 + '    if (pos.x < -0.02) pos.x += 1.04;'#10 + '    if (pos.x >  1.02) pos.x -= 1.04;'#10 + '    if (pos.y < -0.02) pos.y += 1.04;'#10 + '    if (pos.y >  1.02) pos.y -= 1.04;'#10 + '  }'#10 + #10 +
    // Mouse FLUID force: applies to ALL particles (bound + ambient). The
    // mouse swirls particles tangentially (orbit) plus a smoothstep-damped
    // radial nudge - smoothstep(0,0.04,dist) means ZERO force right at the
    // cursor so particles flow AROUND it like a fluid under a finger instead
    // of being blasted away (no more black hole). Bound particles get a
    // gentle 1.4x multiplier so buttons / labels yield like soft rubber under
    // the cursor and spring back (uSpringK pulls them home) - no galaxy swirl.
    '  vec2 mUV = uMousePos / uResolution;'#10 + '  if (mUV.x >= 0.0 && mUV.x <= 1.0 && mUV.y >= 0.0 && mUV.y <= 1.0) {'#10 + '    vec2 d = pos - mUV;'#10 + '    float dist = length(d) + 1e-5;'#10 + '    float ramp = smoothstep(0.0, 0.04, dist);'#10 + '    float infl = exp(-dist * 8.0) * ramp;'#10 + '    float mul = (flags > 0u) ? 1.4 : 1.0;'#10 + '    vel += vec2(-d.y, d.x) / dist * uMouseForce * infl * 1.5 * mul;'#10 + '    vel += d / dist * uMouseForce * infl * 0.5 * mul;'#10 + '  }'#10 + #10 +
    // Click shockwave (background clicks only): expanding ring impulse. Ring
    // radius grows with the click pulse, thickness is Gaussian around the ring.
    // Gated to flags == 0u so it only ripples the ambient dust, never the
    // controls (no earthquake on background clicks).
    '  if (uClickPulse > 0.001 && flags == 0u) {'#10 + '    vec2 cUV = uClickPos / uResolution;'#10 + '    vec2 d = pos - cUV;'#10 + '    float dist = length(d) + 1e-5;'#10 + '    float ringRadius = uClickPulse * 0.5;'#10 + '    float ringThickness = 0.08;'#10 + '    float distToRing = abs(dist - ringRadius);'#10 + '    float ring = exp(-distToRing * distToRing / (2.0 * ringThickness * ringThickness));'#10 + '    vel += d / dist * ring * uClickPulse * 1.2;'#10 + '  }'#10 + #10 + '  pos += vel * dt;'#10 + '  Particles[idx].pos = pos;'#10 + '  Particles[idx].vel = vel;'#10 + #10 +
    // Write. Bound particles (flags > 0u) overwrite their pixel directly
    // via imageStore - NO imageLoad, so dense buttons no longer hit the
    // Read-Modify-Write cache stall that capped the old RMW path. Only
    // ambient dust (flags == 0u) reads the existing pixel and adds softly.
    // Ambient alpha is raised from 0.04 to 0.14 so the visual delta between
    // uAmbientRatio = 0.05 (little dust) and 0.45 (much dust) is immediate
    // and crystal clear when "Toggle Dust" is clicked.
    '  ivec2 px = ivec2(pos * uResolution);'#10 + '  if (px.x >= 0 && px.x < int(uResolution.x) && px.y >= 0 && px.y < int(uResolution.y)) {'#10 + '    vec4 col = unpackCol(Particles[idx].color);'#10 + '    float alpha;'#10 + '    if (flags == 0u) alpha = 0.14;'#10 + '    else if (despawning) alpha = uDespawnFade;'#10 + '    else if (flags == 2u) alpha = 1.0;'#10 + '    else alpha = 0.96;'#10 + '    col.a = alpha;'#10 +
    // Cursor flashlight: a soft light halo traveling with the mouse. Every
    // particle (button body, text, PNG, ambient dust) within a small radius
    // gently brightens; as the cursor moves on, the particle leaves the radius
    // and the TrailDecay pass fades its glow softly back (ambient dust leaves a
    // gentle glowing trail; bound particles light up crisply under the cursor).
    // uHoverGlow (the "Hover Glow" slider) drives brightness / radius.
    // smoothstep(0.065, 0.0, mDist) = full at the cursor, smoothly 0 at the rim
    // - a soft outward falloff with zero derivative at both ends, so it never
    // reads as a hard bright disc, only as a diffuse flashlight pool.
    '    if (mUV.x >= 0.0 && mUV.x <= 1.0 && mUV.y >= 0.0 && mUV.y <= 1.0 && uHoverGlow > 0.001) {'#10 + '      float mDist = distance(pos, mUV);'#10 + '      float cursorGlow = smoothstep(0.065, 0.0, mDist) * uHoverGlow * 0.45;'#10 + '      col.rgb += vec3(cursorGlow);'#10 + '    }'#10 +
    // Focus rim glow: a steady soft rim on the focused pctEdit's bound
    // particles (uFocusRect). Same rounded-box SDF edge technique as the LED
    // runner but WITHOUT the orbiting spot - a calm frame that stays lit while
    // the edit is focused, signalling "you are typing here". Subtle
    // (uFocusGlow ~ 0.5 * uHoverGlow, then * 0.6 here) so it never competes
    // with the caret.
    '    if (uFocusRect.x >= 0.0 && flags > 0u && !despawning && uFocusGlow > 0.001) {'#10 + '      vec2 fUV = uFocusRect.xy / uResolution;'#10 + '      vec2 fSize = uFocusRect.zw / uResolution;'#10 + '      vec2 fMin = fUV;'#10 + '      vec2 fMax = fUV + fSize;'#10 + '      if (home.x >= fMin.x && home.x <= fMax.x && home.y >= fMin.y && home.y <= fMax.y) {'#10 + '        vec2 fp = home - (fUV + fSize * 0.5);'#10 + '        vec2 fh = fSize * 0.5;'#10 + '        float fr = min(fSize.x, fSize.y) * 0.25;'#10 + '        vec2 fq = abs(fp) - (fh - fr);'#10 + '        float fsd = length(max(fq, 0.0)) + min(max(fq.x, fq.y), 0.0) - fr;'#10 + '        float fedgeDist = -fsd / max(min(fSize.x, fSize.y), 1e-5);'#10 + '        float fedgeGlow = exp(-fedgeDist * fedgeDist * 220.0);'#10 + '        col.rgb += vec3(fedgeGlow) * uFocusGlow * 0.6;'#10 + '      }'#10 + '    }'#10 +
    // LED-strip runner on CLICK only (uBtnClickFlash > 0.01): a bright light
    // point travels around the rounded button rim like an LED strip. NO white
    // glow on hover - hover is a pure fluid physics effect (the button's
    // particles yield and swirl under the cursor via the mouse force above).
    // The runner uses the rounded-box SDF edgeGlow so it hugs the contour,
    // and atan(hp.y, hp.x) for the polar angle so the bright spot orbits.
    // It does one calm revolution as the flash decays 1 -> 0 over ~0.6 s.
    '    if (uHoverRect.x >= 0.0 && flags > 0u && !despawning && uBtnClickFlash > 0.01) {'#10 + '      vec2 hUV = uHoverRect.xy / uResolution;'#10 + '      vec2 hSize = uHoverRect.zw / uResolution;'#10 + '      vec2 hMin = hUV;'#10 + '      vec2 hMax = hUV + hSize;'#10 + '      if (home.x >= hMin.x && home.x <= hMax.x && home.y >= hMin.y && home.y <= hMax.y) {'#10 + '        vec2 hp = home - (hUV + hSize * 0.5);'#10 + '        vec2 hh = hSize * 0.5;'#10 + '        float r = min(hSize.x, hSize.y) * 0.25;'#10 + '        vec2 q = abs(hp) - (hh - r);'#10 + '        float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;'#10 + '        float edgeDist = -sd / max(min(hSize.x, hSize.y), 1e-5);'#10 + '        float edgeGlow = exp(-edgeDist * edgeDist * 180.0);'#10 + '        float ang = atan(hp.y, hp.x);'#10 + '        float runner = pow(max(0.0, cos(ang - (1.0 - uBtnClickFlash) * 6.28318)), 12.0);'#10 + '        col.rgb += vec3(runner) * edgeGlow * uBtnClickFlash * uHoverGlow * 2.2;'#10 + '      }'#10 + '    }'#10 +
    // === UI STYLE (bound, non-despawning particles only) ===
    // pusHolographic (1): sci-fi hologram - only every 2nd bound particle
    // renders (sparse), as a crisp 1x1 dot, modulated by a horizontal scanline
    // wave and tinted with a cool cyan/neon shimmer.
    // pusSolidFluid (0): unchanged - falls through to the flags-based write.
    '    if (flags > 0u && !despawning) {'#10 + '      if (uUIStyle == 1) {'#10 + '        if ((idx % 2u) != 0u) return;'#10 + '        col.rgb *= (0.75 + 0.25 * sin(pos.y * uResolution.y * 1.4 + uTime * 5.0));'#10 + '        col.rgb = col.rgb * 1.25 + vec3(0.0, 0.14, 0.24);'#10 + '        col.a = 1.0;'#10 + '      }'#10 + '    }'#10 +
    // Cursor caret glow (pctEdit): a soft glow on bound particles whose home is
    // in uCursorRect (a thin vertical strip just past the focused edit's text),
    // modulated by uCursorBlink (smooth 0..1 envelope, 0.5 s blink). Drawn in
    // the shader so the caret blinks WITHOUT ever re-rendering / re-uploading
    // the edit slot - the mouse-deformation of the edit is no longer reset
    // every 0.5 s.
    '    if (uCursorRect.x >= 0.0 && flags > 0u && !despawning && uCursorBlink > 0.001) {'#10 + '      vec2 crUV = uCursorRect.xy / uResolution;'#10 + '      vec2 crSize = uCursorRect.zw / uResolution;'#10 + '      if (home.x >= crUV.x && home.x <= crUV.x + crSize.x && home.y >= crUV.y && home.y <= crUV.y + crSize.y) {'#10 + '        col.rgb += vec3(uCursorBlink) * 1.4;'#10 + '        col.a = max(col.a, uCursorBlink);'#10 + '      }'#10 + '    }'#10 +
    // Bound write. flags == 2u = text pixel: sharp 1x1 splat, ALWAYS written
    // at full alpha 1.0 so letter strokes stay crisp and sit ON TOP of the
    // body. flags == 1u = body pixel: 2x2 splat for gap-free coverage, but it
    // NEVER overwrites a pixel whose existing.a > 0.98 (a text pixel) - so as
    // body and text particles wobble (breathing / mouse fluid) past each other
    // the caption cannot flicker or get eaten by the body splat.
    // Styled writes (pusHolographic) render as a single crisp 1x1 dot and take
    // precedence over the flags-based 2x2 body splat.
    '    bool styled = (uUIStyle == 1) && flags > 0u && !despawning;'#10 + '    if (styled) {'#10 + '      imageStore(uOutput, px, col);'#10 + '    } else if (flags == 2u) {'#10 + '      imageStore(uOutput, px, col);'#10 + '      if (px.x + 1 < int(uResolution.x)) imageStore(uOutput, px + ivec2(1, 0), col);'#10 + '    } else if (flags == 1u) {'#10 + '      vec4 ex0 = imageLoad(uOutput, px);'#10 + '      if (ex0.a <= 0.98) imageStore(uOutput, px, col);'#10 + '      if (px.x + 1 < int(uResolution.x)) { vec4 ex1 = imageLoad(uOutput, px + ivec2(1, 0)); if (ex1.a <= 0.98) imageStore(uOutput, px + ivec2(1, 0), col); }'#10 + '      if (px.y + 1 < int(uResolution.y)) { vec4 ex2 = imageLoad(uOutput, px + ivec2(0, 1)); if (ex2.a <= 0.98) imageStore(uOutput, px + ivec2(0, 1), col); }'#10 + '      if (px.x + 1 < int(uResolution.x) && px.y + 1 < int(uResolution.y)) { vec4 ex3 = imageLoad(uOutput, px + ivec2(1, 1)); if (ex3.a <= 0.98) imageStore(uOutput, px + ivec2(1, 1), col); }'#10 +
    // Ambient layering: only write where no control pixel already sits.
    // Control pixels (text at 1.0, body at 0.96 decayed to ~0.9) block ambient
    // writes (existing.a >= 0.5) so the background stays cleanly BEHIND UI.
    '    } else {'#10 + '      vec4 existing = imageLoad(uOutput, px);'#10 + '      if (existing.a < 0.5) {'#10 + '        vec4 outc = clamp(existing + col * alpha, vec4(0.0), vec4(1.0));'#10 + '        outc.a = max(existing.a, alpha);'#10 + '        imageStore(uOutput, px, outc);'#10 + '      }'#10 + '    }'#10 + '  }'#10 + '}';
  DECAY_SRC: AnsiString = '#version 430 core'#10 + 'layout(local_size_x = 16, local_size_y = 16) in;'#10 + 'layout(rgba8, binding = 0) uniform image2D uOutput;'#10 + 'uniform vec2 uResolution;'#10 + 'uniform float uDecayFactor;'#10 + 'void main(){'#10 + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 + '  if (px.x >= int(uResolution.x) || px.y >= int(uResolution.y)) return;'#10 + '  vec4 c = imageLoad(uOutput, px);'#10 + '  c.rgb *= uDecayFactor;'#10 + '  c.rgb = max(c.rgb - 0.03, vec3(0.0));'#10 + '  c.a   = max(c.a   - 0.06, 0.0);'#10 +
    // Hard clamp: additive particle writes can never white out the
    // background completely. 0.85 keeps everything a bit muted.
    '  c.rgb = min(c.rgb, vec3(0.85));'#10 + '  imageStore(uOutput, px, c);'#10 + '}';
var
  PartShader, DecShader: Cardinal;
begin
  PartShader := CompileShader(GL_COMPUTE_SHADER, PARTICLE_SRC);
  DecShader := CompileShader(GL_COMPUTE_SHADER, DECAY_SRC);
  if (PartShader = 0) or (DecShader = 0) then
    Exit;
  FParticleProgram := LinkProgram([PartShader]);
  FDecayProgram := LinkProgram([DecShader]);

  if FParticleProgram <> 0 then
  begin
    glUseProgram(FParticleProgram);
    FLocP_DeltaTime := glGetUniformLocation(FParticleProgram, 'uDeltaTime');
    FLocP_Resolution := glGetUniformLocation(FParticleProgram, 'uResolution');
    FLocP_MousePos := glGetUniformLocation(FParticleProgram, 'uMousePos');
    FLocP_MouseVel := glGetUniformLocation(FParticleProgram, 'uMouseVel');
    FLocP_HoverRect := glGetUniformLocation(FParticleProgram, 'uHoverRect');
    FLocP_HoverGlow := glGetUniformLocation(FParticleProgram, 'uHoverGlow');
    FLocP_FocusRect := glGetUniformLocation(FParticleProgram, 'uFocusRect');
    FLocP_FocusGlow := glGetUniformLocation(FParticleProgram, 'uFocusGlow');
    FLocP_ClickPulse := glGetUniformLocation(FParticleProgram, 'uClickPulse');
    FLocP_ClickPos := glGetUniformLocation(FParticleProgram, 'uClickPos');
    FLocP_ParticleCount := glGetUniformLocation(FParticleProgram, 'uParticleCount');
    FLocP_Time := glGetUniformLocation(FParticleProgram, 'uTime');
    FLocP_AmbientRatio := glGetUniformLocation(FParticleProgram, 'uAmbientRatio');
    FLocP_BtnClickFlash := glGetUniformLocation(FParticleProgram, 'uBtnClickFlash');
    FLocP_DespawnRect := glGetUniformLocation(FParticleProgram, 'uDespawnRect');
    FLocP_DespawnFade := glGetUniformLocation(FParticleProgram, 'uDespawnFade');
    FLocP_SpringK := glGetUniformLocation(FParticleProgram, 'uSpringK');
    FLocP_MouseForce := glGetUniformLocation(FParticleProgram, 'uMouseForce');
    FLocP_BgMode := glGetUniformLocation(FParticleProgram, 'uBgMode');
    FLocP_DespawnMode := glGetUniformLocation(FParticleProgram, 'uDespawnMode');
    FLocP_CursorRect := glGetUniformLocation(FParticleProgram, 'uCursorRect');
    FLocP_CursorBlink := glGetUniformLocation(FParticleProgram, 'uCursorBlink');
    FLocP_UIStyle := glGetUniformLocation(FParticleProgram, 'uUIStyle');
  end;
  if FDecayProgram <> 0 then
  begin
    glUseProgram(FDecayProgram);
    FLocD_Resolution := glGetUniformLocation(FDecayProgram, 'uResolution');
    FLocD_DecayFactor := glGetUniformLocation(FDecayProgram, 'uDecayFactor');
  end;
  glUseProgram(0);
end;

{==============================================================================
  GL resources: SSBO, output texture, FBO
==============================================================================}
procedure TGPUAliveComponentHost.InitGLResources;
var
  TotalSimPixels: Int64;
begin
  // Pre-allocate the SSBO once at PARTICLE_MAX capacity. The ACTIVE
  // particle count (FParticleCount) is recomputed every frame in
  // RenderEffect from the live sim resolution (TotalSimPixels, 1x - the
  // 2x2 splat means each bound particle already covers 4 texels, so 1x
  // density + splat fills controls 100 % at half the GPU compute of the
  // old 2x path), capped at PARTICLE_MAX, and UploadSSBO only refreshes
  // the active prefix via glBufferSubData - no reallocation when the
  // window resizes between windowed and fullscreen.
  FMaxParticles := PARTICLE_MAX;

  // 2 particles per sim pixel for a lush, fine particle look, capped at
  // PARTICLE_MAX. The 2x2 splat means each bound body particle covers 4
  // texels, so controls fill 100 % densely; the extra budget goes into a
  // finer ambient dust cloud and bigger per-control slots.
  TotalSimPixels := Int64(FSimWidth) * Int64(FSimHeight);
  if TotalSimPixels < 1 then
    TotalSimPixels := 1;
  FParticleCount := Cardinal(TotalSimPixels * 2);
  if FParticleCount > FMaxParticles then
    FParticleCount := FMaxParticles;
  if FParticleCount < 1024 then
    FParticleCount := 1024;

  SetLength(FParticleCPU, NativeInt(FMaxParticles) * 32);
  FillChar(Pointer(FParticleCPU)^, Length(FParticleCPU), 0);

  glGenBuffers(1, @FParticleSSBO);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
  glBufferData(GL_SHADER_STORAGE_BUFFER, NativeInt(FMaxParticles) * 32, nil, GL_DYNAMIC_COPY);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TGPUAliveComponentHost.SeedAmbientParticles(StartIdx, EndIdx: Integer);
var
  I: Integer;
  P: PByte;
begin
  if Length(FParticleCPU) < NativeInt(EndIdx + 1) * 32 then
    Exit;
  for I := StartIdx to EndIdx do
  begin
    P := @FParticleCPU[I * 32];
    PSingle(P + 0)^ := Random;
    PSingle(P + 4)^ := Random;
    PSingle(P + 8)^ := (Random - 0.5) * 0.01;
    PSingle(P + 12)^ := (Random - 0.5) * 0.01;
    PSingle(P + 16)^ := -1;              // homePos.x = -1 marks ambient
    PSingle(P + 20)^ := -1;
    PCardinal(P + 24)^ := $8040A0FF;     // soft blue-white dust
    PCardinal(P + 28)^ := 0;             // flags = ambient
  end;
end;

procedure TGPUAliveComponentHost.UploadSSBO;
var
  ActiveBytes: NativeInt;
begin
  if FParticleSSBO = 0 then
    Exit;
  // Only refresh the active prefix [0..FParticleCount) via glBufferSubData.
  // The SSBO was pre-allocated at FMaxParticles*32 in InitGLResources, so
  // this never reallocates - shrinking or growing the active count when
  // the sim resolution changes is a single cheap sub-data upload, no
  // buffer orphaning, no driver-side re-allocation stall.
  ActiveBytes := NativeInt(FParticleCount) * 32;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
  if Assigned(glBufferSubData) then
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, ActiveBytes, Pointer(FParticleCPU))
  else
    glBufferData(GL_SHADER_STORAGE_BUFFER, ActiveBytes, Pointer(FParticleCPU), GL_DYNAMIC_COPY);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TGPUAliveComponentHost.UploadSlot(SlotStart, SlotCap: Cardinal);
var
  Offset, Size: NativeInt;
begin
  if FParticleSSBO = 0 then
    Exit;
  if (SlotCap = 0) or (SlotStart >= FMaxParticles) then
    Exit;
  // Clamp the slot to the pre-allocated SSBO capacity.
  if NativeInt(SlotStart) + NativeInt(SlotCap) > NativeInt(FMaxParticles) then
    SlotCap := Cardinal(FMaxParticles) - SlotStart;
  // Partial upload of ONE control's slot [SlotStart .. SlotStart+SlotCap)
  // via glBufferSubData with an offset. Every other slot and the ambient
  // pool on the GPU are left completely untouched, so a morph / spawn /
  // despawn of one control never interrupts the drifting background or
  // disturbs a single particle of any other control.
  Offset := NativeInt(SlotStart) * 32;
  Size := NativeInt(SlotCap) * 32;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
  if Assigned(glBufferSubData) then
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, Offset, Size, @FParticleCPU[NativeInt(SlotStart) * 32])
  else
  begin
    // No glBufferSubData: fall back to a full re-upload of the active
    // prefix. Still correct, just uploads everything.
    glBufferData(GL_SHADER_STORAGE_BUFFER, NativeInt(FParticleCount) * 32, Pointer(FParticleCPU), GL_DYNAMIC_COPY);
  end;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TGPUAliveComponentHost.UpdateSimResolution(ViewW, ViewH: Integer);
var
  Scale: Single;
begin
  FViewWidth := ViewW;
  FViewHeight := ViewH;
  // Resolution scaling driven by the SimResolutionScale property (default
  // 0.75). Below FULLSCREEN_VIEW_W/H (1600x1000) we render 1:1 for full
  // sharpness so windowed-mode text stays crisp. Above it (fullscreen) we
  // scale to Round(View*Scale) - 0.75*0.75 = 0.56 cuts the pixel count by
  // ~1.8x while keeping the sim sharp enough for legible captions.
  if (ViewW > FULLSCREEN_VIEW_W) or (ViewH > FULLSCREEN_VIEW_H) then
    Scale := FSimResolutionScale
  else
    Scale := 1.0;
  FSimWidth := Max(2, Round(ViewW * Scale));
  FSimHeight := Max(2, Round(ViewH * Scale));
end;

{==============================================================================
  Per-frame compute dispatch
==============================================================================}
procedure TGPUAliveComponentHost.DispatchDecayPass;
var
  GroupsX, GroupsY: Cardinal;
begin
  if (FDecayProgram = 0) or (FTexWidth <= 0) or (FTexHeight <= 0) then
    Exit;
  glUseProgram(FDecayProgram);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  glUniform2f(FLocD_Resolution, FTexWidth, FTexHeight);
  glUniform1f(FLocD_DecayFactor, FTrailPersistence);
  GroupsX := (Cardinal(FTexWidth) + 15) div 16;
  GroupsY := (Cardinal(FTexHeight) + 15) div 16;
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  glUseProgram(0);
end;

procedure TGPUAliveComponentHost.ApplyMouseStateUniforms;
var
  MX, MY, MDX, MDY: Single;
  CPulse: Single;
  BtnFlash: Single;
  CX, CY: Single;
  HoverIdx: Integer;
  HoverRect: array[0..3] of Single;
  HoverGlow: Single;
  FocusIdx: Integer;
  FocusRect: array[0..3] of Single;
  FocusGlow: Single;
  BlinkAccum: Single;
  CursorOn: Boolean;
  CursorRect: array[0..3] of Single;
  CursorBlink: Single;
  Ctl: TParticleControl;
  ScaleX, ScaleY: Single;
  DespawnRect: array[0..3] of Single;
  DespawnFade: Single;
  DespawnIdx: Integer;
  DespawnCtl: TParticleControl;
  CurTxt: string;
  TxtSize: TSize;
  FontH: HFONT;
  OldFont: HGDIOBJ;
  PadLeft, CurW: Single;
begin
  FMouseLock.Enter;
  try
    MX := FMouseX;
    MY := FMouseY;
    MDX := FMouseDX;
    MDY := FMouseDY;
    FMouseDX := 0;
    FMouseDY := 0;
    CPulse := FClickPulse;
    BtnFlash := FBtnClickFlash;
    CX := FClickX;
    CY := FClickY;
    HoverIdx := FHoveredIndex;
    FocusIdx := FFocusedIndex;
    BlinkAccum := FCursorBlinkAccum;
    CursorOn := FCursorOnPhase;
  finally
    FMouseLock.Leave;
  end;

  // The UI thread stores mouse / click coords in VIEW pixels, but the
  // compute shaders run at (FSimWidth, FSimHeight) and divide every
  // position by uResolution = (FSimWidth, FSimHeight). Scale view->sim
  // here so the shader's uMousePos / uResolution still yields the correct
  // UV in both windowed (1:1) and half-res fullscreen (2:1) modes.
  if FViewWidth > 0 then
    ScaleX := FSimWidth / FViewWidth
  else
    ScaleX := 1.0;
  if FViewHeight > 0 then
    ScaleY := FSimHeight / FViewHeight
  else
    ScaleY := 1.0;

  glUniform2f(FLocP_MousePos, MX * ScaleX, MY * ScaleY);
  glUniform2f(FLocP_MouseVel, MDX * ScaleX, MDY * ScaleY);

  if (HoverIdx >= 0) and (HoverIdx < Length(FControls)) then
  begin
    FControlsLock.Enter;
    try
      Ctl := FControls[HoverIdx];
    finally
      FControlsLock.Leave;
    end;
    HoverRect[0] := Ctl.Bounds.Left * ScaleX;
    HoverRect[1] := Ctl.Bounds.Top * ScaleY;
    HoverRect[2] := (Ctl.Bounds.Right - Ctl.Bounds.Left) * ScaleX;
    HoverRect[3] := (Ctl.Bounds.Bottom - Ctl.Bounds.Top) * ScaleY;
    HoverGlow := FHoverGlowStrength;
  end
  else
  begin
    HoverRect[0] := -1;
    HoverRect[1] := -1;
    HoverRect[2] := -1;
    HoverRect[3] := -1;
    HoverGlow := 0;
  end;
  glUniform4f(FLocP_HoverRect, HoverRect[0], HoverRect[1], HoverRect[2], HoverRect[3]);
  glUniform1f(FLocP_HoverGlow, HoverGlow);
  glUniform1f(FLocP_ClickPulse, CPulse);
  glUniform2f(FLocP_ClickPos, CX * ScaleX, CY * ScaleY);
  // uBtnClickFlash drives the decaying edge-flash on the last clicked
  // button (1.0 -> 0.0 over ~0.25 s). Set to 1.0 by MouseDown on a button.
  glUniform1f(FLocP_BtnClickFlash, BtnFlash);

  // Focus rim glow: if a pctEdit is focused, send its sim-space rect + a
  // subtle glow so the shader lights up the edit's rim (uFocusRect). This is
  // decenter than the hover/LED glow - it stays steady while the edit is
  // focused, signalling "you are typing here".
  FocusRect[0] := -1; FocusRect[1] := -1; FocusRect[2] := -1; FocusRect[3] := -1;
  FocusGlow := 0;
  if (FocusIdx >= 0) and (FocusIdx < Length(FControls)) then
  begin
    FControlsLock.Enter;
    try
      Ctl := FControls[FocusIdx];
    finally
      FControlsLock.Leave;
    end;
    if (Ctl.CtlType = pctEdit) and Ctl.Visible and not Ctl.Despawning then
    begin
      FocusRect[0] := Ctl.Bounds.Left * ScaleX;
      FocusRect[1] := Ctl.Bounds.Top * ScaleY;
      FocusRect[2] := (Ctl.Bounds.Right - Ctl.Bounds.Left) * ScaleX;
      FocusRect[3] := (Ctl.Bounds.Bottom - Ctl.Bounds.Top) * ScaleY;
      // Subtle: half the hover-glow strength so the rim reads as a soft focus
      // frame, not a bright ring competing with the caret.
      FocusGlow := FHoverGlowStrength * 0.5;
    end;
  end;
  glUniform4f(FLocP_FocusRect, FocusRect[0], FocusRect[1], FocusRect[2], FocusRect[3]);
  glUniform1f(FLocP_FocusGlow, FocusGlow);

  // Cursor caret (pctEdit): uCursorBlink is a smooth 0..1 envelope over the
  // 1 s blink cycle (the positive half of a sine - bright pulse during the
  // on-phase 0..0.5 s, zero during the off-phase 0.5..1 s). uCursorRect is a
  // thin vertical strip in SIM pixels sitting just past the focused edit's
  // text end; -1 when no edit is focused OR the blink is in its off-phase.
  // The text width is measured with the SAME font RenderControlToCanvas draws
  // (same height / weight / family) so the caret lands exactly after the last
  // typed character. The caret is rendered entirely in the shader from these
  // two uniforms - it NEVER triggers RenderAndAssignSlot / UploadSlot, so the
  // mouse-deformation of the edit is no longer reset every 0.5 s.
  CursorBlink := 0;
  CursorRect[0] := -1; CursorRect[1] := -1; CursorRect[2] := -1; CursorRect[3] := -1;
  if CursorOn then
    CursorBlink := Max(0, Sin(BlinkAccum * 2 * Pi));
  if (FocusIdx >= 0) and (FocusIdx < Length(FControls)) and CursorOn and (FDIBDC <> 0) then
  begin
    FControlsLock.Enter;
    try
      Ctl := FControls[FocusIdx];
    finally
      FControlsLock.Leave;
    end;
    if (Ctl.CtlType = pctEdit) and Ctl.Visible and not Ctl.Despawning then
    begin
      CurTxt := Ctl.Text;
      PadLeft := Round(12 * ScaleX);
      CurW := Max(2, Round(2 * ScaleX));
      TxtSize.cx := 0;
      TxtSize.cy := 0;
      // Font height mirrors RenderControlToCanvas: 0.48 * sim-scaled control
      // height, negative = character height, bold Segoe UI, ClearType.
      FontH := CreateFont(
        -Max(8, Round((Ctl.Bounds.Bottom - Ctl.Bounds.Top) * ScaleY * 0.48)),
        0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
        OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH or FF_DONTCARE, 'Segoe UI');
      if FontH <> 0 then
      begin
        OldFont := SelectObject(FDIBDC, FontH);
        if Length(CurTxt) > 0 then
          GetTextExtentPoint32W(FDIBDC, PChar(CurTxt), Length(CurTxt), TxtSize);
        CursorRect[0] := Ctl.Bounds.Left * ScaleX + PadLeft + TxtSize.cx;
        CursorRect[1] := Ctl.Bounds.Top * ScaleY;
        CursorRect[2] := CurW;
        CursorRect[3] := (Ctl.Bounds.Bottom - Ctl.Bounds.Top) * ScaleY;
        SelectObject(FDIBDC, OldFont);
        DeleteObject(FontH);
      end;
    end;
  end;
  glUniform4f(FLocP_CursorRect, CursorRect[0], CursorRect[1], CursorRect[2], CursorRect[3]);
  glUniform1f(FLocP_CursorBlink, CursorBlink);

  // Despawn uniforms: if a control is despawning (RemoveParticleControl),
  // send its sim-space rect + the current fade (1.0 -> 0.0) so the shader
  // lets that control's bound particles lose their spring, drift apart and
  // fade out. Read under FControlsLock (same lock RemoveParticleControl /
  // TickDespawn use).
  DespawnIdx := -1;
  DespawnFade := 0;
  DespawnRect[0] := -1; DespawnRect[1] := -1; DespawnRect[2] := -1; DespawnRect[3] := -1;
  FControlsLock.Enter;
  try
    DespawnIdx := FDespawnControlIdx;
    if (DespawnIdx >= 0) and (DespawnIdx < Length(FControls)) then
    begin
      DespawnCtl := FControls[DespawnIdx];
      DespawnFade := EnsureRange(FDespawnTimer / DESPAWN_DURATION, 0.0, 1.0);
      DespawnRect[0] := DespawnCtl.Bounds.Left * ScaleX;
      DespawnRect[1] := DespawnCtl.Bounds.Top * ScaleY;
      DespawnRect[2] := (DespawnCtl.Bounds.Right - DespawnCtl.Bounds.Left) * ScaleX;
      DespawnRect[3] := (DespawnCtl.Bounds.Bottom - DespawnCtl.Bounds.Top) * ScaleY;
    end;
  finally
    FControlsLock.Leave;
  end;
  if FLocP_DespawnRect >= 0 then
    glUniform4f(FLocP_DespawnRect, DespawnRect[0], DespawnRect[1], DespawnRect[2], DespawnRect[3]);
  if FLocP_DespawnFade >= 0 then
    glUniform1f(FLocP_DespawnFade, DespawnFade);

  // Live-tunable effect uniforms (forwarded every frame so changing the
  // public properties is instant - no mask rebuild or SSBO re-upload).
  if FLocP_SpringK >= 0 then
    glUniform1f(FLocP_SpringK, FSpringStiffness);
  if FLocP_MouseForce >= 0 then
    glUniform1f(FLocP_MouseForce, FMouseRepelForce);
  if FLocP_BgMode >= 0 then
    glUniform1i(FLocP_BgMode, Ord(FBackgroundEffect));
  if FLocP_DespawnMode >= 0 then
    glUniform1i(FLocP_DespawnMode, Ord(FDespawnEffect));
  // Visual UI style (SolidFluid / Holographic) - read by the particle
  // shader's bound-particle render branch. Live-tunable: switching UIStyle is
  // instant, with no mask rebuild / SSBO re-upload.
  if FLocP_UIStyle >= 0 then
    glUniform1i(FLocP_UIStyle, Ord(FUIStyle));
end;

procedure TGPUAliveComponentHost.DispatchComputeFrame(DeltaTime, TimeSec: Double);
var
  TotalGroups: Int64;
  GroupsX, GroupsY: Cardinal;
begin
  if (FParticleProgram = 0) or (FParticleSSBO = 0) or (FTexWidth <= 0) then
    Exit;
  glUseProgram(FParticleProgram);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FParticleSSBO);
  glBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);

  glUniform1f(FLocP_DeltaTime, DeltaTime);
  glUniform1f(FLocP_Time, TimeSec);
  glUniform2f(FLocP_Resolution, FTexWidth, FTexHeight);
  ApplyMouseStateUniforms;
  glUniform1ui(FLocP_ParticleCount, FParticleCount);
  // uAmbientRatio drives the per-particle ambient budget gate directly on
  // the GPU - no mask rebuild, no SSBO re-upload when AmbientDensity changes.
  glUniform1f(FLocP_AmbientRatio, FAmbientDensity);

  // local_size_x = 256: halves the workgroup count vs. the old 64, which
  // means less dispatch overhead and better wave occupancy on the SMs.
  TotalGroups := (Int64(FParticleCount) + 255) div 256;
  if TotalGroups > 65535 then
  begin
    GroupsX := 65535;
    GroupsY := Cardinal((TotalGroups + GroupsX - 1) div GroupsX);
  end
  else
  begin
    GroupsX := Cardinal(TotalGroups);
    GroupsY := 1;
  end;
  glDispatchCompute(GroupsX, GroupsY, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT or GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  glUseProgram(0);

  FMouseLock.Enter;
  try
    FClickPulse := Max(0, FClickPulse - Single(DeltaTime) * 2.5);
    // uBtnClickFlash decays slowly (~0.6 s at * 1.6) so the LED-strip runner
    // has time to travel once, calmly and visibly, around the button rim.
    FBtnClickFlash := Max(0, FBtnClickFlash - Single(DeltaTime) * 1.6);
    // Caret blink: accumulate time over a 1 s cycle and set the on-phase for
    // the first 0.5 s. The phase drives uCursorRect (sent only during the
    // on-phase) + uCursorBlink (a smooth sine envelope) in
    // ApplyMouseStateUniforms. The caret is rendered ENTIRELY in the shader
    // now - the blink NEVER triggers RenderAndAssignSlot / UploadSlot, so the
    // mouse-deformation of the focused edit is no longer reset every 0.5 s.
    FCursorBlinkAccum := FCursorBlinkAccum + Single(DeltaTime);
    if FCursorBlinkAccum >= 1.0 then
      FCursorBlinkAccum := FCursorBlinkAccum - 1.0;
    FCursorOnPhase := FCursorBlinkAccum < 0.5;
  finally
    FMouseLock.Leave;
  end;
end;

{==============================================================================
  Layout mask

  GDI paints the controls into an offscreen DIB. Because GDI ignores
  alpha, every pixel ends up opaque - including the black background.
  The alpha fix below restores the "painted / not painted" semantics by
  zeroing alpha on pure black pixels and setting alpha=255 everywhere
  else.

  For labels this is exactly what we want: the label rectangle is filled
  with black, the text is drawn in white on top, so only the text pixels
  survive the alpha fix and the label becomes a pure text silhouette.
==============================================================================}
procedure TGPUAliveComponentHost.MarkLayoutDirty;
begin
  FLayoutMaskLock.Enter;
  try
    FLayoutDirty := True;
  finally
    FLayoutMaskLock.Leave;
  end;
end;

procedure TGPUAliveComponentHost.FixAlphaMask(AIsPNG: Boolean);
var
  Px: PCardinal;
  PixIdx: Integer;
  A: Byte;
begin
  // Walk the GDI DIB (which the caller has already cleared to black and
  // painted control(s) into) and decide per pixel whether it is opaque or
  // transparent, then copy the finished mask into FLayoutMask under the lock.
  //  - Non-PNG (labels / buttons / edits): pure-black -> transparent (the
  //    black rect background), everything else -> opaque (text + body fill).
  //    This turns labels into pure text silhouettes and keeps buttons opaque.
  //  - PNG: use the SOURCE alpha channel (preserved verbatim by StretchDIBits'
  //    SRCCOPY into the 32-bit DIB) with a low threshold of 4 so faint
  //    anti-aliased edges / glows survive. A non-black RGB fallback is OR-ed
  //    in so the PNG also renders fully if a GDI path ever zeroes the alpha
  //    byte. Pure-black-zero-alpha (true transparent background) still drops.
  //    This fixes "PNG missing pixels": a pure-black-but-opaque logo pixel
  //    (RGB=0, alpha=$FF) used to be discarded by the pure-black RGB check.
  if FDIBDC = 0 then
    Exit;
  Px := PCardinal(FDIBBits);
  for PixIdx := 0 to (FTexWidth * FTexHeight) - 1 do
  begin
    if AIsPNG then
    begin
      A := Byte(Px^ shr 24);
      if (A > 4) or ((Px^ and $00FFFFFF) <> 0) then
        Px^ := Px^ or $FF000000       // visible PNG pixel (alpha>4 or non-black)
      else
        Px^ := 0;                     // true transparent background
    end
    else
    begin
      if (Px^ and $00FFFFFF) = 0 then
        Px^ := 0                      // pure black -> transparent background
      else
        Px^ := Px^ or $FF000000;      // anything else -> opaque
    end;
    Inc(Px);
  end;
  FLayoutMaskLock.Enter;
  try
    if Length(FLayoutMask) >= FTexWidth * FTexHeight * 4 then
      System.Move(FDIBBits^, Pointer(FLayoutMask)^, FTexWidth * FTexHeight * 4);
  finally
    FLayoutMaskLock.Leave;
  end;
end;

procedure TGPUAliveComponentHost.RenderControlToCanvas(const ACtl: TParticleControl; AIndex: Integer);
var
  R: TRect;
  BrushCol: COLORREF;
  Br: HBRUSH;
  OldObj: HGDIOBJ;
  TextLen: Integer;
  URect: TRect;
  BI: TBitmapInfo;
  ScaleX, ScaleY: Single;
  CornerRadius: Integer;
  FontH: HFONT;
  OldFont: HGDIOBJ;
  BorderCol: COLORREF;
  Pen: HPEN;
  PaddingLeft: Integer;
  DrawStr: string;
  DrawFlags: Cardinal;
begin
  if (not ACtl.Visible) or (FDIBDC = 0) then
    Exit;

  // Control bounds are stored in VIEW pixels (the UI thread writes them via
  // AddParticleButton etc.). The DIB is sim-sized (FSimWidth x FSimHeight),
  // so scale every control rect view->sim before painting - otherwise
  // controls would paint outside the DIB in half-res fullscreen and the
  // mask would lose them entirely.
  if FViewWidth > 0 then
    ScaleX := FSimWidth / FViewWidth
  else
    ScaleX := 1.0;
  if FViewHeight > 0 then
    ScaleY := FSimHeight / FViewHeight
  else
    ScaleY := 1.0;
  R := Rect(
    Round(ACtl.Bounds.Left * ScaleX),
    Round(ACtl.Bounds.Top * ScaleY),
    Round(ACtl.Bounds.Right * ScaleX),
    Round(ACtl.Bounds.Bottom * ScaleY));

  // ACtl.Color is packed 0xAARRGGBB (FMX TAlphaColor layout). GDI wants
  // COLORREF = 0x00BBGGRR, so extract R/G/B from the upper three bytes.
  BrushCol := RGB(Byte((ACtl.Color shr 16) and $FF), Byte((ACtl.Color shr 8) and $FF), Byte((ACtl.Color shr 0) and $FF));

  // Rounded-corner radius for buttons / edits, in SIM pixels (14px design
  // radius scaled view->sim). RoundRect wants the full ellipse diameter = 2*r.
  CornerRadius := Round(14 * ScaleX);
  if CornerRadius < 2 then
    CornerRadius := 2;

  case ACtl.CtlType of
    pctButton:
      begin
        // Rounded rectangle: every pixel inside the rounded shape becomes
        // opaque, so the button is a dense particle capsule with rounded
        // corners. NULL_PEN avoids a GDI border outline; the corner radius
        // scales with the view->sim factor so it stays proportional at
        // half-res fullscreen.
        Br := CreateSolidBrush(BrushCol);
        OldObj := SelectObject(FDIBDC, Br);
        SelectObject(FDIBDC, GetStockObject(NULL_PEN));
        RoundRect(FDIBDC, R.Left, R.Top, R.Right, R.Bottom, CornerRadius * 2, CornerRadius * 2);
        SelectObject(FDIBDC, OldObj);
        DeleteObject(Br);
      end;
    pctEdit:
      begin
        // Dark rounded-rect fill = the field body. NULL_PEN so the fill has
        // no GDI outline; the body pixels become body-flag particles.
        Br := CreateSolidBrush(BrushCol);
        OldObj := SelectObject(FDIBDC, Br);
        SelectObject(FDIBDC, GetStockObject(NULL_PEN));
        RoundRect(FDIBDC, R.Left, R.Top, R.Right, R.Bottom, CornerRadius * 2, CornerRadius * 2);
        SelectObject(FDIBDC, OldObj);
        DeleteObject(Br);
        // Fine lighter border: lighten the fill ~48 per channel (clamped) and
        // overdraw the rounded outline with a 1px pen + HOLLOW_BRUSH so only
        // the rim is touched. The rim particles read as a subtle frame; when
        // the edit is focused the shader adds a soft glow on top (uFocusRect).
        BorderCol := RGB(
          Byte(Min(255, Integer((ACtl.Color shr 16) and $FF) + 48)),
          Byte(Min(255, Integer((ACtl.Color shr 8) and $FF) + 48)),
          Byte(Min(255, Integer(ACtl.Color and $FF) + 48)));
        Pen := CreatePen(PS_SOLID, 1, BorderCol);
        OldObj := SelectObject(FDIBDC, Pen);
        SelectObject(FDIBDC, GetStockObject(HOLLOW_BRUSH));
        RoundRect(FDIBDC, R.Left, R.Top, R.Right, R.Bottom, CornerRadius * 2, CornerRadius * 2);
        SelectObject(FDIBDC, OldObj);
        DeleteObject(Pen);
      end;
    pctPNG:
      begin
        // StretchDIBits blits the decoded BGRA bytes into the DIB,
        // scaled to the control bounds.
        if (Length(ACtl.BGRA) >= ACtl.ImgW * ACtl.ImgH * 4) and (ACtl.ImgW > 0) and (ACtl.ImgH > 0) then
        begin
          FillChar(BI, SizeOf(BI), 0);
          BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
          BI.bmiHeader.biWidth := ACtl.ImgW;
          BI.bmiHeader.biHeight := -ACtl.ImgH;
          BI.bmiHeader.biPlanes := 1;
          BI.bmiHeader.biBitCount := 32;
          BI.bmiHeader.biCompression := BI_RGB;
          StretchDIBits(FDIBDC, R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, 0, 0, ACtl.ImgW, ACtl.ImgH, Pointer(ACtl.BGRA), BI, DIB_RGB_COLORS, SRCCOPY);
        end;
      end;
  else
    begin
        // pctLabel: paint ONLY the text. The rectangle stays black,
        // the text is white. The alpha fix below then discards the
        // black background and keeps only the text pixels, so the
        // label becomes a pure text silhouette of particles.
      Br := CreateSolidBrush(RGB(0, 0, 0));
      FillRect(FDIBDC, R, Br);
      DeleteObject(Br);
    end;
  end;

  SetBkMode(FDIBDC, TRANSPARENT);
  SetTextColor(FDIBDC, RGB($FF, $FF, $FF));
  // Sharp TrueType font instead of the bitmap SYSTEM_FONT (which rendered
  // blurry / blocky at every scale - the "120x80 pixelbrei" look). Height
  // proportional to the control height so text fills the button / label;
  // CLEARTYPE_QUALITY for crisp anti-aliased edges; Segoe UI Bold for a
  // clean modern look. Created per call (cheap, and height varies per
  // control) and deleted immediately after to avoid a GDI handle leak.
  FontH := CreateFont(
    -Max(8, Round((R.Bottom - R.Top) * 0.48)),  // negative = character height
    0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
    OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
    DEFAULT_PITCH or FF_DONTCARE, 'Segoe UI');
  if FontH <> 0 then
  begin
    OldFont := SelectObject(FDIBDC, FontH);
    // Text layout by type: buttons / labels are centred; edits are
    // left-aligned with a left padding so the caption sits inside the field
    // body. The blinking caret is NOT appended here anymore - it is drawn
    // entirely in the particle compute shader (uCursorRect / uCursorBlink) so
    // the blink never re-renders / re-uploads the edit slot (which used to
    // reset the mouse-deformation every 0.5 s).
    DrawStr := ACtl.Text;
    DrawFlags := DT_CENTER or DT_VCENTER or DT_SINGLELINE;
    URect := R;
    if ACtl.CtlType = pctEdit then
    begin
      PaddingLeft := Round(12 * ScaleX);
      URect := Rect(R.Left + PaddingLeft, R.Top, R.Right - 2, R.Bottom);
      DrawFlags := DT_LEFT or DT_VCENTER or DT_SINGLELINE;
    end;
    TextLen := Length(DrawStr);
    if TextLen > 0 then
      DrawText(FDIBDC, PChar(DrawStr), TextLen, URect, DrawFlags);
    SelectObject(FDIBDC, OldFont);
    DeleteObject(FontH);
  end;
end;

procedure TGPUAliveComponentHost.RebuildLayoutMaskIfNeeded;
var
  SpawnIdx: Integer;
  FullRebuild: Boolean;
  SlotStart, SlotCap: Cardinal;
  I, Count: Integer;
  DoOne: Boolean;
  Explode: Boolean;
begin
  FLayoutMaskLock.Enter;
  try
    // Two independent triggers, consumed here:
    //   FSpawnControlIdx        -> spawn ONE new control's slot (swarm in)
    //   FLayoutDirty            -> full rebuild (resize / despawn complete / init)
    //   per-control NeedsRebuild -> morph EVERY flagged control's slot (text
    //                                change / focus move / caret), read below
    //                                directly off FControls under FControlsLock.
    // FULL REBUILD HAS PRIORITY: if FLayoutDirty is set (e.g. at startup when
    // all controls were just added, or after a resize), every control must be
    // re-rendered into its own slot from scratch. A lingering spawn index from
    // the same frame would otherwise only touch one slot and leave the rest
    // invisible until the next resize - that was the "only PNG visible at
    // startup, buttons appear after resize" bug. So when FullRebuild is set we
    // drop the spawn and do the full rebuild.
    FullRebuild := FLayoutDirty;
    if FullRebuild then
      SpawnIdx := -1
    else
      SpawnIdx := FSpawnControlIdx;
    FSpawnControlIdx := -1;
    FLayoutDirty := False;
  finally
    FLayoutMaskLock.Leave;
  end;
  if FDIBDC = 0 then
    Exit;

  if FullRebuild then
    // Full rebuild: every control re-rendered into its own slot + ambient
    // reseeded + full SSBO upload. Used for startup / resize / despawn
    // completion. Takes priority over morph/spawn so all controls are
    // visible immediately.
    ReassignParticlesFromMask
  else
  begin
    // Morph path: render + scan + (explode OR gentle-retarget) + upload EVERY
    // control flagged NeedsRebuild, each into its OWN slot. Looping over ALL
    // controls (instead of a single global FMorphControlIdx) means several
    // controls can rebuild in the SAME frame. This is the fix for the
    // backspace / typing delay in the edit: HandleKeyInput flags the EDIT,
    // then the edit's OnChange fires UpdateControlText which flags the
    // mirrored LABEL - both are now rebuilt this frame, so the new / deleted
    // letter appears in the edit instantly instead of being overwritten by
    // the label's morph request. The old FMorphControlIdx2 (focus move
    // between two edits) is subsumed: both edits are simply flagged and both
    // rebuild together.
    FControlsLock.Enter;
    try
      Count := Length(FControls);
    finally
      FControlsLock.Leave;
    end;
    for I := 0 to Count - 1 do
    begin
      FControlsLock.Enter;
      try
        DoOne := (I < Length(FControls)) and FControls[I].NeedsRebuild;
        if DoOne then
        begin
          FControls[I].NeedsRebuild := False;
          Explode := FControls[I].ExplodeOnRebuild;
          SlotStart := FControls[I].SlotStart;
          SlotCap := FControls[I].SlotCapacity;
        end;
      finally
        FControlsLock.Leave;
      end;
      if DoOne then
      begin
        RenderAndAssignSlot(I, True, False, Explode);
        UploadSlot(SlotStart, SlotCap);
      end;
    end;

    // Spawn path: render + scatter ONLY the new control's slot, then upload
    // ONLY that slot. Rarely co-occurs with a morph (you don't add a control
    // and change text in the same frame), so it runs after the morph loop.
    if SpawnIdx >= 0 then
    begin
      RenderAndAssignSlot(SpawnIdx, False, True);
      FControlsLock.Enter;
      try
        if (SpawnIdx >= 0) and (SpawnIdx < Length(FControls)) then
        begin
          SlotStart := FControls[SpawnIdx].SlotStart;
          SlotCap := FControls[SpawnIdx].SlotCapacity;
        end
        else
          Exit;
      finally
        FControlsLock.Leave;
      end;
      UploadSlot(SlotStart, SlotCap);
    end;
  end;
end;

{==============================================================================
  Particle reassignment

  Every opaque mask pixel becomes one bound particle at that position,
  with the mask pixel's color. The remaining particles are respawned as
  ambient dust.
==============================================================================}
procedure TGPUAliveComponentHost.ReassignParticlesFromMask;
var
  AmbientMax: Cardinal;
  BoundStart: Cardinal;
  BoundUsed: Cardinal;
  I, N: Integer;
begin
  if (FTexWidth <= 0) or (FTexHeight <= 0) or (FParticleCount = 0) then
    Exit;

  // FIXED SSBO LAYOUT with per-control slots:
  //   [0 .. AmbientMax-1]                                -> ambient dust pool
  //   [AmbientMax .. AmbientMax + N*SLOT_CAPACITY)       -> one fixed slot
  //                                                        per visible control
  //   [AmbientMax + N*SLOT_CAPACITY .. FParticleCount-1] -> unused tail
  // Each control owns a non-overlapping SLOT_CAPACITY block, so a morph /
  // spawn / despawn of ONE control touches ONLY its own slot - no particle
  // ever flies between a label, a button and a PNG.
  AmbientMax := Cardinal(Round(FParticleCount * MAX_AMBIENT_RATIO));
  if AmbientMax > FParticleCount - 1 then
    AmbientMax := FParticleCount - 1;
  BoundStart := AmbientMax;

  FControlsLock.Enter;
  try
    N := Length(FControls);
  finally
    FControlsLock.Leave;
  end;
  BoundUsed := Cardinal(N) * SLOT_CAPACITY;
  if BoundStart + BoundUsed > FParticleCount then
    BoundUsed := FParticleCount - BoundStart;

  FBoundStart := BoundStart;
  FBoundCount := BoundUsed;
  FAmbientCount := AmbientMax;

  // Full rebuild: reseed the ambient pool + the entire bound region (which
  // includes every slot + the unused tail) so stale particles from a removed
  // control or a resize don't linger.
  SeedAmbientParticles(0, AmbientMax - 1);
  SeedAmbientParticles(BoundStart, FParticleCount - 1);

  // Render + assign each control to its own fixed slot. Invisible controls
  // get skipped (their slot stays ambient-seeded). RenderAndAssignSlot paints
  // ONLY that one control into the DIB, scans it and fills its slot - so
  // every control's mask is isolated and no pixels leak between slots.
  for I := 0 to N - 1 do
    RenderAndAssignSlot(I, False, False);

  UploadSSBO;
end;

procedure TGPUAliveComponentHost.RenderAndAssignSlot(AIndex: Integer; AMorph: Boolean; ASpawn: Boolean; AExplode: Boolean);
var
  Ctl: TParticleControl;
  SlotStart, SlotCap: Cardinal;
  X, Y: Integer;
  Idx: Cardinal;
  C: Cardinal;
  P: PByte;
  JitterX, JitterY: Single;
  HomeX, HomeY: Single;
  CenterX, CenterY: Single;
  ScaleX, ScaleY: Single;
  CurFlag: Cardinal;
  OldFlags: Cardinal;
  R8, G8, B8: Byte;
  Br: HBRUSH;
begin
  if (FTexWidth <= 0) or (FTexHeight <= 0) or (FParticleCount = 0) or (FDIBDC = 0) then
    Exit;
  // Snapshot the control (UI thread may mutate FControls concurrently).
  FControlsLock.Enter;
  try
    if (AIndex < 0) or (AIndex >= Length(FControls)) then
      Exit;
    Ctl := FControls[AIndex];
  finally
    FControlsLock.Leave;
  end;
  if not Ctl.Visible then
    Exit;

  // This control's fixed, non-overlapping slot in the SSBO.
  SlotStart := FBoundStart + Cardinal(AIndex) * SLOT_CAPACITY;
  if SlotStart >= FParticleCount then
    Exit;  // no room for this control's slot
  SlotCap := SLOT_CAPACITY;
  if SlotStart + SlotCap > FParticleCount then
    SlotCap := FParticleCount - SlotStart;

  // Per-pixel flag is computed inside the scan loop below: labels -> always
  // flags=2 (text, 1x1 splat); PNGs -> always flags=1 (body, 2x2 splat);
  // buttons -> flags=2 for bright text pixels (R,G,B > 240, the pure white
  // caption RenderControlToCanvas drew on top of the dark body) and flags=1
  // for the coloured body. This keeps button captions sharp and lets the
  // shader's alpha layering protect them from the body splat.

  // Spawn centre (in UV) for the swarm-formation scatter.
  if (FViewWidth > 0) and (FViewHeight > 0) then
  begin
    ScaleX := FSimWidth / FViewWidth;
    ScaleY := FSimHeight / FViewHeight;
    CenterX := ((Ctl.Bounds.Left + Ctl.Bounds.Right) * 0.5 * ScaleX) / FTexWidth;
    CenterY := ((Ctl.Bounds.Top + Ctl.Bounds.Bottom) * 0.5 * ScaleY) / FTexHeight;
  end
  else
  begin
    CenterX := 0;
    CenterY := 0;
  end;

  // Render ONLY this control into the DIB: clear to black, paint the control,
  // then fix the alpha (pure black -> transparent, everything else -> opaque).
  // This isolates the control's mask so its pixels land in its own slot and
  // nowhere else.
  Br := CreateSolidBrush(RGB(0, 0, 0));
  FillRect(FDIBDC, Rect(0, 0, FTexWidth, FTexHeight), Br);
  DeleteObject(Br);
  RenderControlToCanvas(Ctl, AIndex);
  FixAlphaMask(Ctl.CtlType = pctPNG);

  // Scan the DIB and assign every opaque pixel to a particle in this slot.
  Idx := SlotStart;
  for Y := 0 to FTexHeight - 1 do
  begin
    for X := 0 to FTexWidth - 1 do
    begin
      C := PCardinal(PByte(FDIBBits) + (Y * FTexWidth + X) * 4)^;
      if (C and $FF000000) = 0 then
        Continue;
      if Idx >= SlotStart + SlotCap then
        Break;
      P := @FParticleCPU[Idx * 32];

      // Sub-pixel jitter on homePos to break the exact-grid alignment that
      // opens hairline gaps between neighbours (reads as black scratches).
      JitterX := (Random - 0.5) / FTexWidth;
      JitterY := (Random - 0.5) / FTexHeight;
      HomeX := X / FTexWidth + JitterX;
      HomeY := Y / FTexHeight + JitterY;
      PSingle(P + 16)^ := HomeX;
      PSingle(P + 20)^ := HomeY;

      // Per-pixel flag: labels -> text (2); buttons & edits -> bright pixel =
      // text (2, the white caption / caret '|'), else body (1, the coloured
      // body / dark field fill / lighter rim); PNGs -> body (1).
      if Ctl.CtlType = pctLabel then
        CurFlag := 2
      else if Ctl.CtlType in [pctButton, pctEdit] then
      begin
        R8 := Byte((C shr 16) and $FF);
        G8 := Byte((C shr 8) and $FF);
        B8 := Byte(C and $FF);
        if (R8 > 240) and (G8 > 240) and (B8 > 240) then
          CurFlag := 2   // bright = caption text / caret (pure white)
        else
          CurFlag := 1;  // coloured body / dark field fill / rim
      end
      else
        CurFlag := 1;    // PNG body

      if ASpawn then
      begin
        // Spawn formation - FSpawnEffect selects the start distribution:
        //   pseSwarmIn : scatter around centre (default)
        //   pseImplode : start far out, fly inward
        //   pseRiseUp  : start below, rise up
        //   pseInstant : start at home, at rest
        case FSpawnEffect of
          pseImplode:
            begin
              PSingle(P + 0)^ := CenterX + (Random - 0.5) * 0.6;
              PSingle(P + 4)^ := CenterY + (Random - 0.5) * 0.6;
              PSingle(P + 8)^ := (CenterX - PSingle(P + 0)^) * 0.8;
              PSingle(P + 12)^ := (CenterY - PSingle(P + 4)^) * 0.8;
            end;
          pseRiseUp:
            begin
              PSingle(P + 0)^ := HomeX + (Random - 0.5) * 0.02;
              PSingle(P + 4)^ := CenterY + 0.25 + (Random - 0.5) * 0.05;
              PSingle(P + 8)^ := 0;
              PSingle(P + 12)^ := -0.15 - (Random) * 0.1;
            end;
          pseInstant:
            begin
              PSingle(P + 0)^ := HomeX;
              PSingle(P + 4)^ := HomeY;
              PSingle(P + 8)^ := 0;
              PSingle(P + 12)^ := 0;
            end;
        else { pseSwarmIn }
          begin
            PSingle(P + 0)^ := CenterX + (Random - 0.5) * 0.15;
            PSingle(P + 4)^ := CenterY + (Random - 0.5) * 0.15;
            PSingle(P + 8)^ := (Random - 0.5) * 0.22;
            PSingle(P + 12)^ := (Random - 0.5) * 0.22;
          end;
        end;
      end
      else if AMorph then
      begin
        // Morph transition - FMorphEffect selects the impulse. Crucially,
        // NEW particles (old flags == 0 = background dust sitting in this
        // slot's tail) start near the control CENTRE, so a growing caption
        // pulls fresh material from its LOCAL background cloud - no more
        // particles flying over from the PNG or the buttons.
        OldFlags := PCardinal(P + 28)^;
        if not AExplode then
        begin
          // Gentle morph (keystroke / caret blink): no scatter impulse.
          // Existing bound particles keep their position and glide to the
          // (possibly shifted) new home via the spring; fresh particles
          // (old flags == 0 = background dust in this slot's tail) start
          // near the control centre and drift in. The edit text reflows
          // smoothly instead of exploding apart on every keystroke.
          if OldFlags = 0 then
          begin
            PSingle(P + 0)^ := CenterX + (Random - 0.5) * 0.06;
            PSingle(P + 4)^ := CenterY + (Random - 0.5) * 0.06;
          end;
          // pos (P+0, P+4) for OldFlags>0 intentionally untouched - spring glides.
          PSingle(P + 8)^ := 0;
          PSingle(P + 12)^ := 0;
        end
        else
        begin
        case FMorphEffect of
          pmeScatterSnap:
            begin
              // Big scatter velocity, pos -> home (snaps together from a cloud)
              PSingle(P + 0)^ := HomeX;
              PSingle(P + 4)^ := HomeY;
              PSingle(P + 8)^ := (Random - 0.5) * 0.55;
              PSingle(P + 12)^ := (Random - 0.5) * 0.55;
            end;
          pmeWaveSweep:
            begin
              // Horizontal sweep impulse scaled by HomeX (left -> right)
              if OldFlags > 0 then
              begin
                PSingle(P + 8)^ := (0.3 + HomeX * 0.4) + (Random - 0.5) * 0.1;
                PSingle(P + 12)^ := (Random - 0.5) * 0.1;
              end
              else
              begin
                PSingle(P + 0)^ := CenterX + (Random - 0.5) * 0.08;
                PSingle(P + 4)^ := CenterY + (Random - 0.5) * 0.08;
                PSingle(P + 8)^ := 0.25;
                PSingle(P + 12)^ := 0;
              end;
            end;
          pmeInstant:
            begin
              // No impulse - just retarget home
              PSingle(P + 0)^ := HomeX;
              PSingle(P + 4)^ := HomeY;
              PSingle(P + 8)^ := 0;
              PSingle(P + 12)^ := 0;
            end;
        else { pmeCloudReform }
          begin
            // Old bound particles keep their pos + explode; new (background)
            // particles start near the centre + small impulse.
            if OldFlags > 0 then
            begin
              // pos (P+0, P+4) intentionally untouched - scatters from where it was
              PSingle(P + 8)^ := (Random - 0.5) * 0.35;
              PSingle(P + 12)^ := (Random - 0.5) * 0.35;
            end
            else
            begin
              PSingle(P + 0)^ := CenterX + (Random - 0.5) * 0.1;
              PSingle(P + 4)^ := CenterY + (Random - 0.5) * 0.1;
              PSingle(P + 8)^ := (Random - 0.5) * 0.25;
              PSingle(P + 12)^ := (Random - 0.5) * 0.25;
            end;
          end;
        end;
        end;  // close explode-morph else-branch (AExplode = True)
      end
      else
      begin
        // Full rebuild: start at home, at rest.
        PSingle(P + 0)^ := HomeX;
        PSingle(P + 4)^ := HomeY;
        PSingle(P + 8)^ := 0;
        PSingle(P + 12)^ := 0;
      end;

      // Colour: mask pixel is already 0xAARRGGBB (alpha fix set $FF). Copy
      // directly - NO R/B swap (the shader's unpackCol expects this layout).
      PCardinal(P + 24)^ := C;
      PCardinal(P + 28)^ := CurFlag;   // 1 = body (2x2 splat), 2 = text (1x1)
      Inc(Idx);
    end;
    if Idx >= SlotStart + SlotCap then
      Break;
  end;

  // Surplus slot particles (control shrank / caption shorter): demote to
  // ambient (flags=0) so the uAmbientRatio gate skips them. An EXPLODE morph
  // (AExplode=True, e.g. the Morph button) gives them a random scatter
  // velocity so the old caption blows apart into a cloud. A GENTLE morph
  // (AExplode=False, e.g. a backspace keystroke) yanks them straight off the
  // viewport (pos = -2.0, vel = 0) so the deleted letters vanish
  // DELAY-FREE instead of drifting away over several frames (no ghost delay).
  // The ambient wrap will slowly return them as faint background dust, but by
  // then they have dissolved below visibility.
  while Idx < SlotStart + SlotCap do
  begin
    P := @FParticleCPU[Idx * 32];
    PCardinal(P + 28)^ := 0;            // flags = ambient
    if AExplode then
    begin
      PSingle(P + 8)^ := (Random - 0.5) * 0.3;
      PSingle(P + 12)^ := (Random - 0.5) * 0.3;
    end
    else
    begin
      // Typing / backspace: instantly off-screen (no drift, no ghost).
      PSingle(P + 0)^ := -2.0;
      PSingle(P + 4)^ := -2.0;
      PSingle(P + 8)^ := 0;
      PSingle(P + 12)^ := 0;
    end;
    Inc(Idx);
  end;

  // Persist the slot assignment so the control knows its particle range
  // (used by the despawn uniform + future per-slot operations).
  FControlsLock.Enter;
  try
    if (AIndex >= 0) and (AIndex < Length(FControls)) then
    begin
      FControls[AIndex].SlotStart := SlotStart;
      FControls[AIndex].SlotCapacity := SlotCap;
    end;
  finally
    FControlsLock.Leave;
  end;
end;

{==============================================================================
  Virtual control management (UI thread only)
==============================================================================}
function TGPUAliveComponentHost.FindControlByName(const AName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FControls) do
    if SameText(FControls[I].Name, AName) then
    begin
      Result := I;
      Exit;
    end;
end;

function TGPUAliveComponentHost.AddParticleLabel(const AName: string; X, Y, W, H: Integer; const AText: string; AColor: Cardinal): Integer;
var
  Ctl: TParticleControl;
begin
  FillChar(Ctl, SizeOf(Ctl), 0);
  Ctl.Name := AName;
  Ctl.CtlType := pctLabel;
  Ctl.Bounds := Rect(X, Y, X + W, Y + H);
  Ctl.Text := AText;
  Ctl.Color := AColor;
  Ctl.Visible := True;
  // NeedsRebuild stays False (FillChar zeroed it): the spawn path
  // (FSpawnControlIdx set below) renders this new control, not the morph loop.
  FControlsLock.Enter;
  try
    Result := Length(FControls);
    SetLength(FControls, Result + 1);
    FControls[Result] := Ctl;
  finally
    FControlsLock.Leave;
  end;
  // Spawn path: set FSpawnControlIdx so RebuildLayoutMaskIfNeeded calls
  // RenderAndAssignSlot(Result, spawn=True) which scatters the new control's
  // bound particles around its centre (swarm formation) and uploads ONLY
  // that slot. The background and all existing controls keep running.
  FLayoutMaskLock.Enter;
  try
    FSpawnControlIdx := Result;
  finally
    FLayoutMaskLock.Leave;
  end;
end;

function TGPUAliveComponentHost.AddParticleButton(const AName: string; X, Y, W, H: Integer; const AText: string; AColor: Cardinal; AOnClick: TParticleClickEvent): Integer;
var
  Ctl: TParticleControl;
begin
  FillChar(Ctl, SizeOf(Ctl), 0);
  Ctl.Name := AName;
  Ctl.CtlType := pctButton;
  Ctl.Bounds := Rect(X, Y, X + W, Y + H);
  Ctl.Text := AText;
  Ctl.Color := AColor;
  Ctl.OnClick := AOnClick;
  Ctl.Visible := True;
  // NeedsRebuild stays False (FillChar zeroed it): the spawn path
  // (FSpawnControlIdx set below) renders this new control, not the morph loop.
  FControlsLock.Enter;
  try
    Result := Length(FControls);
    SetLength(FControls, Result + 1);
    FControls[Result] := Ctl;
  finally
    FControlsLock.Leave;
  end;
  // Spawn path: set FSpawnControlIdx so RebuildLayoutMaskIfNeeded calls
  // RenderAndAssignSlot(Result, spawn=True) which scatters the new control's
  // bound particles around its centre (swarm formation) and uploads ONLY
  // that slot. The background and all existing controls keep running.
  FLayoutMaskLock.Enter;
  try
    FSpawnControlIdx := Result;
  finally
    FLayoutMaskLock.Leave;
  end;
end;

function TGPUAliveComponentHost.AddParticlePNG(const AName: string; X, Y, W, H: Integer; const ABGRABytes: TBytes; ImgW, ImgH: Integer): Integer;
var
  Ctl: TParticleControl;
begin
  FillChar(Ctl, SizeOf(Ctl), 0);
  Ctl.Name := AName;
  Ctl.CtlType := pctPNG;
  Ctl.Bounds := Rect(X, Y, X + W, Y + H);
  Ctl.Text := '';
  Ctl.Color := $FFFFFFFF;
  Ctl.BGRA := Copy(ABGRABytes, 0, Length(ABGRABytes));
  Ctl.ImgW := ImgW;
  Ctl.ImgH := ImgH;
  Ctl.Visible := True;
  // NeedsRebuild stays False (FillChar zeroed it): the spawn path
  // (FSpawnControlIdx set below) renders this new control, not the morph loop.
  FControlsLock.Enter;
  try
    Result := Length(FControls);
    SetLength(FControls, Result + 1);
    FControls[Result] := Ctl;
  finally
    FControlsLock.Leave;
  end;
  // Spawn path: set FSpawnControlIdx so RebuildLayoutMaskIfNeeded calls
  // RenderAndAssignSlot(Result, spawn=True) which scatters the new control's
  // bound particles around its centre (swarm formation) and uploads ONLY
  // that slot. The background and all existing controls keep running.
  FLayoutMaskLock.Enter;
  try
    FSpawnControlIdx := Result;
  finally
    FLayoutMaskLock.Leave;
  end;
end;

function TGPUAliveComponentHost.AddParticleEdit(const AName, AInitialText: string; X, Y, W, H: Integer; AColor: TAlphaColor; AOnChange: TNotifyEvent): Integer;
var
  Ctl: TParticleControl;
begin
  FillChar(Ctl, SizeOf(Ctl), 0);
  Ctl.Name := AName;
  Ctl.CtlType := pctEdit;
  Ctl.Bounds := Rect(X, Y, X + W, Y + H);
  Ctl.Text := AInitialText;
  Ctl.Color := Cardinal(AColor);
  Ctl.OnChange := AOnChange;
  Ctl.Visible := True;
  // NeedsRebuild stays False (FillChar zeroed it): the spawn path
  // (FSpawnControlIdx set below) renders this new control, not the morph loop.
  FControlsLock.Enter;
  try
    Result := Length(FControls);
    SetLength(FControls, Result + 1);
    FControls[Result] := Ctl;
  finally
    FControlsLock.Leave;
  end;
  // Spawn path: set FSpawnControlIdx so RebuildLayoutMaskIfNeeded calls
  // RenderAndAssignSlot(Result, spawn=True) which scatters the new edit's
  // bound particles around its centre (swarm formation) and uploads ONLY
  // that slot. The background and all existing controls keep running.
  FLayoutMaskLock.Enter;
  try
    FSpawnControlIdx := Result;
  finally
    FLayoutMaskLock.Leave;
  end;
end;

procedure TGPUAliveComponentHost.UpdateControlText(const AName, ANewText: string; AGentle: Boolean);
var
  Idx: Integer;
begin
  FControlsLock.Enter;
  try
    Idx := FindControlByName(AName);
    if Idx < 0 then
      Exit;
    FControls[Idx].Text := ANewText;
    // Flag this control for a same-frame rebuild. RebuildLayoutMaskIfNeeded
    // loops over ALL controls and renders + uploads every flagged one, so a
    // keystroke in the edit (HandleKeyInput flags the edit) AND this mirrored
    // label update both rebuild together - no more FMorphControlIdx race
    // where the label's request overwrote the edit's.
    // AGentle=False (default) -> ExplodeOnRebuild=True: the old caption blows
    // apart into a cloud and reassembles (the dramatic morph used by the
    // Morph button). AGentle=True -> ExplodeOnRebuild=False: particles glide
    // to their new home without any scatter impulse, used by
    // DoParticleEditChange so the mirrored label reflows smoothly on every
    // keystroke instead of exploding each time.
    FControls[Idx].NeedsRebuild := True;
    FControls[Idx].ExplodeOnRebuild := not AGentle;
  finally
    FControlsLock.Leave;
  end;
end;

procedure TGPUAliveComponentHost.SetControlVisible(const AName: string; AVisible: Boolean);
var
  Idx: Integer;
begin
  FControlsLock.Enter;
  try
    Idx := FindControlByName(AName);
    if Idx < 0 then
      Exit;
    if FControls[Idx].Visible = AVisible then
      Exit;
    FControls[Idx].Visible := AVisible;
    FControls[Idx].NeedsRebuild := True;
  finally
    FControlsLock.Leave;
  end;
  MarkLayoutDirty;
end;

function TGPUAliveComponentHost.HitTestButton(X, Y: Integer): Integer;
var
  I: Integer;
  Ctl: TParticleControl;
begin
  Result := -1;
  FControlsLock.Enter;
  try
    for I := 0 to High(FControls) do
    begin
      Ctl := FControls[I];
      if (Ctl.CtlType = pctButton) and Ctl.Visible and Ctl.Bounds.Contains(Point(X, Y)) then
      begin
        Result := I;
        Exit;
      end;
    end;
  finally
    FControlsLock.Leave;
  end;
end;

function TGPUAliveComponentHost.HitTestEditable(X, Y: Integer): Integer;
var
  I: Integer;
  Ctl: TParticleControl;
begin
  Result := -1;
  // Iterate topmost-first (last added paints on top) so overlapping edits
  // resolve to the visually-front one.
  FControlsLock.Enter;
  try
    for I := High(FControls) downto 0 do
    begin
      Ctl := FControls[I];
      if (Ctl.CtlType = pctEdit) and Ctl.Visible and not Ctl.Despawning and Ctl.Bounds.Contains(Point(X, Y)) then
      begin
        Result := I;
        Exit;
      end;
    end;
  finally
    FControlsLock.Leave;
  end;
end;

function TGPUAliveComponentHost.GetControlCount: Integer;
begin
  FControlsLock.Enter;
  try
    Result := Length(FControls);
  finally
    FControlsLock.Leave;
  end;
end;

function TGPUAliveComponentHost.GetControlDisplay(AIndex: Integer): string;
var
  Ctl: TParticleControl;
  Prefix: string;
begin
  Result := '';
  FControlsLock.Enter;
  try
    if (AIndex < 0) or (AIndex >= Length(FControls)) then
      Exit;
    Ctl := FControls[AIndex];
    case Ctl.CtlType of
      pctButton: Prefix := '[Button]';
      pctLabel:  Prefix := '[Label]';
      pctPNG:    Prefix := '[PNG]';
      pctEdit:   Prefix := '[Edit]';
    else
      Prefix := '[?]';
    end;
    Result := Prefix + ' ' + Ctl.Name;
  finally
    FControlsLock.Leave;
  end;
end;

function TGPUAliveComponentHost.GetControlText(const AName: string): string;
var
  Idx: Integer;
begin
  Result := '';
  FControlsLock.Enter;
  try
    Idx := FindControlByName(AName);
    if Idx < 0 then
      Exit;
    Result := FControls[Idx].Text;
  finally
    FControlsLock.Leave;
  end;
end;

procedure TGPUAliveComponentHost.RemoveParticleControl(AIndex: Integer);
var
  Shift: Boolean;
begin
  FControlsLock.Enter;
  try
    if (AIndex < 0) or (AIndex >= Length(FControls)) then
      Exit;
    // Only one control despawns at a time. If a DIFFERENT control is already
    // despawning, finish it immediately (remove it from FControls), then
    // adjust AIndex if the removal shifted it.
    Shift := False;
    if (FDespawnControlIdx >= 0) and (FDespawnControlIdx <> AIndex) then
    begin
      Shift := (FDespawnControlIdx < AIndex);
      CompleteDespawnInternal;
    end;
    if Shift then
      Dec(AIndex);
    if (AIndex < 0) or (AIndex >= Length(FControls)) then
      Exit;
    if FControls[AIndex].Despawning then
      Exit;
    // Arm the despawn: the shader (via uDespawnRect / uDespawnFade) lets
    // this control's bound particles lose their spring, drift apart and
    // fade over DESPAWN_DURATION. TickDespawn (render thread) completes the
    // removal when the timer elapses.
    FControls[AIndex].Despawning := True;
    FControls[AIndex].DespawnTimer := DESPAWN_DURATION;
    FDespawnControlIdx := AIndex;
    FDespawnTimer := DESPAWN_DURATION;
  finally
    FControlsLock.Leave;
  end;
end;

procedure TGPUAliveComponentHost.CompleteDespawnInternal;
var
  I: Integer;
begin
  // Caller MUST hold FControlsLock. Removes the despawning control from
  // FControls (shifting successors down) and resets the despawn slot. The
  // caller is responsible for calling MarkLayoutDirty AFTER releasing the
  // lock (to respect lock ordering with FLayoutMaskLock).
  if (FDespawnControlIdx < 0) or (FDespawnControlIdx >= Length(FControls)) then
  begin
    FDespawnControlIdx := -1;
    Exit;
  end;
  for I := FDespawnControlIdx to Length(FControls) - 2 do
    FControls[I] := FControls[I + 1];
  SetLength(FControls, Length(FControls) - 1);
  FDespawnControlIdx := -1;
  FDespawnTimer := 0;
end;

procedure TGPUAliveComponentHost.TickDespawn(DeltaTime: Double);
var
  NeedRebuild: Boolean;
begin
  // Called from RenderEffect each frame (render thread). Counts down the
  // active despawn timer; when it elapses the control is removed for real
  // and a full reassign reclaims its particles. MarkLayoutDirty is called
  // OUTSIDE the FControlsLock to avoid lock-ordering deadlock with
  // FLayoutMaskLock (RebuildLayoutMaskIfNeeded acquires FLayoutMaskLock
  // first, then FControlsLock).
  NeedRebuild := False;
  FControlsLock.Enter;
  try
    if FDespawnControlIdx >= 0 then
    begin
      FDespawnTimer := FDespawnTimer - Single(DeltaTime);
      if FDespawnTimer <= 0 then
      begin
        CompleteDespawnInternal;
        NeedRebuild := True;
      end;
    end;
  finally
    FControlsLock.Leave;
  end;
  if NeedRebuild then
    MarkLayoutDirty;
end;

{==============================================================================
  Mouse handling (UI thread)

  The base control already routes FMX MouseMove/MouseDown/MouseUp into
  these overrides, so no child HWND subclassing is needed. All state is
  written under FMouseLock; the render thread reads it via
  ApplyMouseStateUniforms.
==============================================================================}
procedure TGPUAliveComponentHost.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  BtnIdx: Integer;
  EditIdx: Integer;
  OldFocus: Integer;
  Ctl: TParticleControl;
  Handler: TParticleClickEvent;
  Xi, Yi: Integer;
begin
  inherited;
  if Button <> TMouseButton.mbLeft then
    Exit;
  Xi := Round(X);
  Yi := Round(Y);

  // Snapshot the current edit focus so we can retire the old caret when it
  // changes. Read lock-free (aligned int; a one-frame-stale value is harmless).
  OldFocus := FFocusedIndex;

  // Edit hit-test FIRST: clicking a pctEdit focuses it and shows the caret.
  // This takes priority over the button hit-test so an edit sitting over a
  // button region still focuses instead of clicking through to the button.
  EditIdx := HitTestEditable(Xi, Yi);
  if EditIdx >= 0 then
  begin
    FMouseLock.Enter;
    try
      FFocusedIndex := EditIdx;
      // Show the caret immediately: jump the blink accumulator to 0.25 s, the
      // peak of the sine envelope (uCursorBlink = sin(0.25*2*pi) = 1.0), so a
      // freshly focused edit shows a full-bright caret right away instead of
      // fading in from 0. The on-phase then continues its natural 0.5 s cycle.
      FCursorOnPhase := True;
      FCursorBlinkAccum := 0.25;
    finally
      FMouseLock.Leave;
    end;
    // Flag the focused edit for a same-frame gentle rebuild so its caret
    // appears. If focus MOVED from another edit, flag the old one too so its
    // caret disappears in the same frame - no orphaned caret left behind.
    // (The old FMorphControlIdx + FMorphControlIdx2 two-slot scheme is
    // subsumed: both edits are simply flagged and both rebuild together.)
    FControlsLock.Enter;
    try
      if (OldFocus >= 0) and (OldFocus < Length(FControls)) and (OldFocus <> EditIdx) then
      begin
        FControls[OldFocus].NeedsRebuild := True;
        FControls[OldFocus].ExplodeOnRebuild := False;
      end;
      if (EditIdx >= 0) and (EditIdx < Length(FControls)) then
      begin
        FControls[EditIdx].NeedsRebuild := True;
        FControls[EditIdx].ExplodeOnRebuild := False;
      end;
    finally
      FControlsLock.Leave;
    end;
    Exit;
  end;

  // Not an edit click: clear the focus. If an edit WAS focused, gently morph
  // it so its '|' caret disappears (otherwise it would linger as orphaned
  // particles until the next resize / morph of that edit).
  if OldFocus >= 0 then
  begin
    FMouseLock.Enter;
    try
      FFocusedIndex := -1;
    finally
      FMouseLock.Leave;
    end;
    // Flag the previously focused edit for a same-frame gentle rebuild so its
    // caret disappears (otherwise it would linger as orphaned particles until
    // the next resize / morph of that edit).
    FControlsLock.Enter;
    try
      if (OldFocus >= 0) and (OldFocus < Length(FControls)) then
      begin
        FControls[OldFocus].NeedsRebuild := True;
        FControls[OldFocus].ExplodeOnRebuild := False;
      end;
    finally
      FControlsLock.Leave;
    end;
  end;

  // Button hit-test. Only a click on the empty background triggers the
  // global shockwave (FClickPulse). A click on a button must NOT shake
  // the rest of the UI - it just fires the button's OnClick handler so
  // the surrounding particle field stays calm. This removes the "screen
  // quake" that used to fire on every Morph / Toggle Dust press and
  // made the whole UI feel jittery.
  BtnIdx := HitTestButton(Xi, Yi);
  if BtnIdx < 0 then
  begin
    FMouseLock.Enter;
    try
      FClickPulse := 1.0;
      FClickX := X;
      FClickY := Y;
    finally
      FMouseLock.Leave;
    end;
    Exit;
  end;

  // Button hit: no global FClickPulse, just a localized edge flash on the
  // clicked button (uBtnClickFlash) plus the click handler. Pin
  // FHoveredIndex to the clicked button so ApplyMouseStateUniforms sends
  // its rect as uHoverRect during the flash - the edge glow + flash then
  // land on exactly the button that was pressed. The rest of the particle
  // field keeps breathing undisturbed (no screen shake).
  FMouseLock.Enter;
  try
    FBtnClickFlash := 1.0;
    FHoveredIndex := BtnIdx;
  finally
    FMouseLock.Leave;
  end;
  FControlsLock.Enter;
  try
    Ctl := FControls[BtnIdx];
  finally
    FControlsLock.Leave;
  end;
  Handler := Ctl.OnClick;
  if Assigned(Handler) then
    Handler(Self);
end;

procedure TGPUAliveComponentHost.HandleKeyInput(var Key: Word; var KeyChar: WideChar);
var
  Idx: Integer;
  Txt: string;
  Changed: Boolean;
  Handler: TNotifyEvent;
begin
  Idx := FFocusedIndex;
  if Idx < 0 then
    Exit;  // no focused edit - let the host form handle the key
  Changed := False;
  Handler := nil;
  FControlsLock.Enter;
  try
    if Idx >= Length(FControls) then
      Exit;
    if FControls[Idx].CtlType <> pctEdit then
      Exit;
    Txt := FControls[Idx].Text;
    if Key = 8 then
    begin
      // vkBack: drop the last character.
      if Txt <> '' then
      begin
        Txt := Copy(Txt, 1, Length(Txt) - 1);
        Changed := True;
      end;
    end
    else if KeyChar >= #32 then
    begin
      // Printable character: append it.
      Txt := Txt + KeyChar;
      Changed := True;
    end;
    if Changed then
    begin
      FControls[Idx].Text := Txt;
      // Flag the edit for a same-frame gentle rebuild (ExplodeOnRebuild =
      // False): the new text reflows smoothly WITHOUT exploding. The edit's
      // OnChange (fired below) typically calls UpdateControlText on the
      // mirrored label, flagging it too - both rebuild together this frame,
      // so the typed / deleted letter appears in the edit instantly.
      FControls[Idx].NeedsRebuild := True;
      FControls[Idx].ExplodeOnRebuild := False;
      Handler := FControls[Idx].OnChange;
    end;
  finally
    FControlsLock.Leave;
  end;
  if not Changed then
    Exit;
  // Restart the caret blink at its peak (accum = 0.25 -> uCursorBlink = 1.0)
  // so the caret is full-bright right after each keystroke, then continues its
  // natural soft pulse / off cycle.
  FMouseLock.Enter;
  try
    FCursorOnPhase := True;
    FCursorBlinkAccum := 0.25;
  finally
    FMouseLock.Leave;
  end;
  // Fire OnChange AFTER the text + rebuild request are committed.
  if Assigned(Handler) then
    Handler(Self);
  // Swallow the key so the host form does not also process it (e.g. the 'H'
  // sandbox toggle firing while typing 'h' into the edit).
  Key := 0;
  KeyChar := #0;
end;

procedure TGPUAliveComponentHost.MouseMove(Shift: TShiftState; X, Y: Single);
var
  OldX, OldY: Single;
  Xi, Yi: Integer;
  NewHover: Integer;
begin
  inherited;
  FMouseLock.Enter;
  try
    OldX := FMouseX;
    OldY := FMouseY;
    if OldX < 0 then
      OldX := X;
    if OldY < 0 then
      OldY := Y;
    FMouseDX := FMouseDX + (X - OldX);
    FMouseDY := FMouseDY + (Y - OldY);
    FMouseX := X;
    FMouseY := Y;
  finally
    FMouseLock.Leave;
  end;
  Xi := Round(X);
  Yi := Round(Y);
  NewHover := HitTestButton(Xi, Yi);
  FMouseLock.Enter;
  try
    if NewHover <> FHoveredIndex then
      FHoveredIndex := NewHover;
  finally
    FMouseLock.Leave;
  end;
end;

procedure TGPUAliveComponentHost.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
end;

procedure TGPUAliveComponentHost.DoMouseLeave;
begin
  inherited;
  FMouseLock.Enter;
  try
    FHoveredIndex := -1;
    FMouseX := -1;
    FMouseY := -1;
    FMouseDX := 0;
    FMouseDY := 0;
  finally
    FMouseLock.Leave;
  end;
end;

{==============================================================================
  GL initialization (runs on the render thread, inside RenderEffect)

  Creates the invisible dummy window, the GL 4.3 Core context, loads the
  entry points, compiles the shaders, allocates the SSBO and textures.

  IMPORTANT: this function leaves the GL context CURRENT. It must NOT
  call wglMakeCurrent(0,0) at the end, because RenderEffect continues to
  use the context right after this function returns.
==============================================================================}
function TGPUAliveComponentHost.InitOffscreenGL: Boolean;
var
  PFD: TPixelFormatDescriptor;
  PF: Integer;
  TempCtx: HGLRC;
  Attribs: array[0..6] of Integer;
begin
  if FGLReady then
    Exit(True);
  if FGLFailed then
    Exit(False);
  try
    FDummyWnd := CreateWindowEx(0, 'STATIC', 'GPUAliveComponentHostDummy', WS_POPUP, 0, 0, 16, 16, 0, 0, HInstance, nil);
    if FDummyWnd = 0 then
      raise Exception.Create('CreateWindowEx failed');
    FDummyDC := GetDC(FDummyWnd);
    FillChar(PFD, SizeOf(PFD), 0);
    PFD.nSize := SizeOf(PFD);
    PFD.nVersion := 1;
    PFD.dwFlags := PFD_DRAW_TO_WINDOW or PFD_SUPPORT_OPENGL or PFD_DOUBLEBUFFER;
    PFD.iPixelType := PFD_TYPE_RGBA;
    PFD.cColorBits := 32;
    PF := ChoosePixelFormat(FDummyDC, @PFD);
    if PF = 0 then
      raise Exception.Create('ChoosePixelFormat failed');
    if not SetPixelFormat(FDummyDC, PF, @PFD) then
      raise Exception.Create('SetPixelFormat failed');
    TempCtx := wglCreateContext(FDummyDC);
    if TempCtx = 0 then
      raise Exception.Create('wglCreateContext (temp) failed');
    if not wglMakeCurrent(FDummyDC, TempCtx) then
      raise Exception.Create('wglMakeCurrent (temp) failed');
    wglCreateContextAttribsARB := wglGetProcAddress('wglCreateContextAttribsARB');
    if Assigned(wglCreateContextAttribsARB) then
    begin
      Attribs[0] := WGL_CONTEXT_MAJOR_VERSION_ARB;
      Attribs[1] := 4;
      Attribs[2] := WGL_CONTEXT_MINOR_VERSION_ARB;
      Attribs[3] := 3;
      Attribs[4] := WGL_CONTEXT_PROFILE_MASK_ARB;
      Attribs[5] := WGL_CONTEXT_CORE_PROFILE_BIT;
      Attribs[6] := 0;
      FGLContext := wglCreateContextAttribsARB(FDummyDC, 0, @Attribs[0]);
      wglMakeCurrent(0, 0);
      wglDeleteContext(TempCtx);
      if FGLContext = 0 then
        raise Exception.Create('wglCreateContextAttribsARB (4.3 core) failed');
      if not wglMakeCurrent(FDummyDC, FGLContext) then
        raise Exception.Create('wglMakeCurrent (4.3 core) failed');
    end
    else
      FGLContext := TempCtx;

    LoadGLFunctions;
    InitShaders;
    if (FParticleProgram = 0) or (FDecayProgram = 0) then
      raise Exception.Create('Shader compilation failed (particle=' + IntToStr(FParticleProgram) + ', decay=' + IntToStr(FDecayProgram) + ')');
    // Compute the simulation resolution from the live control size BEFORE
    // allocating any GL resources. In fullscreen this halves the texture,
    // PBO, layout mask and particle budget immediately (4x bandwidth cut,
    // oriented on uSkiaGPULiquid). InitGLResources sizes the SSBO from
    // FSimWidth/FSimHeight so the active particle count is correct from
    // the very first frame.
    UpdateSimResolution(Max(1, Round(Width)), Max(1, Round(Height)));
    FTexWidth := FSimWidth;
    FTexHeight := FSimHeight;
    InitGLResources;
    ResizeTextures(FTexWidth, FTexHeight);
    FGLReady := True;
    // Deliberately NO wglMakeCurrent(0,0) here. RenderEffect continues
    // to use the context right after this function returns.
    Result := True;
  except
    on E: Exception do
    begin
      FErrorMsg := E.Message;
      FGLFailed := True;
      OutputDebugStringA(PAnsiChar('GPUAliveComponentHost InitOffscreenGL: ' + E.Message));
      Result := False;
    end;
  end;
end;

procedure TGPUAliveComponentHost.CleanupOffscreenGL;
begin
  if FGLContext <> 0 then
  begin
    wglMakeCurrent(FDummyDC, FGLContext);
    if FParticleProgram <> 0 then
      glDeleteProgram(FParticleProgram);
    if FDecayProgram <> 0 then
      glDeleteProgram(FDecayProgram);
    if FOutputTex <> 0 then
      glDeleteTextures(1, @FOutputTex);
    if FParticleSSBO <> 0 then
      glDeleteBuffers(1, @FParticleSSBO);
    if (FPBOs[0] <> 0) or (FPBOs[1] <> 0) then
      glDeleteBuffers(2, @FPBOs[0]);
    wglMakeCurrent(0, 0);
    wglDeleteContext(FGLContext);
    FGLContext := 0;
  end;
  if (FDummyWnd <> 0) and (FDummyDC <> 0) then
    ReleaseDC(FDummyWnd, FDummyDC);
  if FDummyWnd <> 0 then
    DestroyWindow(FDummyWnd);
  FDummyWnd := 0;
  FDummyDC := 0;
  FGLReady := False;
end;

procedure TGPUAliveComponentHost.ResizeTextures(NewW, NewH: Integer);
var
  BI: TBitmapInfo;
  I: Integer;
  NewSize: NativeInt;
begin
  if (NewW <= 0) or (NewH <= 0) then
    Exit;
  if (FOutputTex <> 0) and (FTexWidth = NewW) and (FTexHeight = NewH) then
    Exit;

  if FOutputTex <> 0 then
    glDeleteTextures(1, @FOutputTex);

  FTexWidth := NewW;
  FTexHeight := NewH;

  glGenTextures(1, @FOutputTex);
  glBindTexture(GL_TEXTURE_2D, FOutputTex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, NewW, NewH);
  glBindTexture(GL_TEXTURE_2D, 0);

  SetLength(FPixelBuffer, NewW * NewH * 4);
  FillChar(Pointer(FPixelBuffer)^, Length(FPixelBuffer), 0);

  for I := 0 to 1 do
    if FPBOs[I] <> 0 then
      glDeleteBuffers(1, @FPBOs[I]);
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  glGenBuffers(2, @FPBOs[0]);
  NewSize := NativeInt(NewW) * NativeInt(NewH) * 4;
  FPBOSize := NewSize;
  for I := 0 to 1 do
  begin
    glBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
    glBufferData(GL_PIXEL_PACK_BUFFER, NewSize, nil, GL_STREAM_READ);
  end;
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  FPBOIndex := 0;
  FPBOHasData := False;

  FLayoutMaskLock.Enter;
  try
    SetLength(FLayoutMask, NativeInt(NewW) * NativeInt(NewH) * 4);
    FillChar(Pointer(FLayoutMask)^, Length(FLayoutMask), 0);
    FLayoutDirty := True;
  finally
    FLayoutMaskLock.Leave;
  end;

  if FDIB <> 0 then
  begin
    DeleteObject(FDIB);
    FDIB := 0;
  end;
  if FDIBDC <> 0 then
  begin
    DeleteDC(FDIBDC);
    FDIBDC := 0;
  end;

  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth := NewW;
  BI.bmiHeader.biHeight := -NewH;   // negative height = top-down DIB
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  FDIBInfo := BI;

  FDIBDC := CreateCompatibleDC(0);
  FDIB := CreateDIBSection(FDIBDC, FDIBInfo, DIB_RGB_COLORS, FDIBBits, 0, 0);
  if FDIB <> 0 then
    SelectObject(FDIBDC, FDIB);
end;

{==============================================================================
  Public entry point
==============================================================================}
procedure TGPUAliveComponentHost.InitGL;
begin
  // Just start the base render thread. The GL context is created lazily
  // in RenderEffect on the render thread. Active is idempotent.
  if not Active then
    Active := True;
end;

{==============================================================================
  Base hooks
==============================================================================}
procedure TGPUAliveComponentHost.UpdateLogic(const DeltaTime: Double);
begin
  inherited;
end;

procedure TGPUAliveComponentHost.RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double);
var
  ViewW, ViewH: Integer;
  NeedResize: Boolean;
  TotalSimPixels: Int64;
  ImgInfo: TSkImageInfo;
  GPUImg: ISkImage;
  ReadPBO, WritePBO: Cardinal;
  Mapped: Pointer;
begin
  ViewW := Round(ADest.Width);
  ViewH := Round(ADest.Height);
  if (ViewW <= 0) or (ViewH <= 0) then
    Exit;

  if not Active then
  begin
    inherited RenderEffect(ACanvas, ADest, ATime);
    Exit;
  end;

  // Lazy GL init on the render thread. This is the same pattern as
  // uSkiaGPULiquid and uGPUParticlePageControl.
  if not InitOffscreenGL then
  begin
    ACanvas.Clear($FF1A0000);
    Exit;
  end;

  wglMakeCurrent(FDummyDC, FGLContext);

  // Refresh the simulation resolution every frame. In fullscreen this
  // drops to ViewW/2 x ViewH/2; in windowed mode it stays 1:1. Texture,
  // PBO, layout mask and the active particle count all track FSim* so the
  // whole pipeline scales together when crossing the fullscreen threshold.
  UpdateSimResolution(ViewW, ViewH);

  // Recompute the active particle count from the live sim resolution:
  // TotalSimPixels * 2 (2 particles per sim pixel), capped at PARTICLE_MAX.
  // The 2x2 splat fills controls 100 %; the extra budget is finer ambient
  // dust + bigger per-control slots.
  TotalSimPixels := Int64(FSimWidth) * Int64(FSimHeight);
  if TotalSimPixels < 1 then
    TotalSimPixels := 1;
  FParticleCount := Cardinal(TotalSimPixels * 2);
  if FParticleCount > FMaxParticles then
    FParticleCount := FMaxParticles;
  if FParticleCount < 1024 then
    FParticleCount := 1024;

  // Resize GL resources if either the UI thread flagged a resize OR the
  // sim resolution drifted (crossing the fullscreen threshold). The
  // early-out inside ResizeTextures keeps this a no-op when nothing
  // changed.
  FGLLock.Enter;
  try
    NeedResize := FResizePending;
    FResizePending := False;
  finally
    FGLLock.Leave;
  end;
  if (FSimWidth <> FTexWidth) or (FSimHeight <> FTexHeight) then
    NeedResize := True;
  if NeedResize and (FSimWidth > 1) and (FSimHeight > 1) then
    ResizeTextures(FSimWidth, FSimHeight);

  // Tick the active despawn timer (render thread). If a despawn completes
  // this frame, TickDespawn removes the control and calls MarkLayoutDirty,
  // so the RebuildLayoutMaskIfNeeded right after reclaims its particles in
  // the same frame - no one-frame ghost.
  TickDespawn(1.0 / Max(1, TargetFPS));

  RebuildLayoutMaskIfNeeded;

  // ---- Zero-copy async readback (oriented on uSkiaGPULiquid) ----
  // Map the PREVIOUS frame's PBO and KEEP it mapped through the compute
  // dispatch and the next glGetTexImage. The compute writes to FOutputTex,
  // glGetTexImage writes to the OTHER PBO (WritePBO) - neither touches
  // ReadPBO, so the mapping stays valid. We only unmap AFTER the
  // DrawImageRect below, because TSkImage.MakeFromRaster is lazy and only
  // reads the pointer during the draw. This removes the old System.Move +
  // MakeFromRaster(FPixelBuffer) double-copy of the full sim framebuffer
  // every frame - at half-res fullscreen that was ~4 MB copied per frame
  // for nothing.
  Mapped := nil;
  ReadPBO := 0;
  if FPBOHasData then
  begin
    ReadPBO := FPBOs[FPBOIndex xor 1];
    glBindBuffer(GL_PIXEL_PACK_BUFFER, ReadPBO);
    Mapped := glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, FPBOSize, GL_MAP_READ_BIT);
    // Intentionally do NOT unbind / unmap yet - see the draw section below.
  end;

  DispatchDecayPass;
  DispatchComputeFrame(1.0 / Max(1, TargetFPS), ATime);

  // Issue async glGetTexImage into the write PBO. Returns immediately;
  // the DMA is consumed one frame later at the top of this procedure.
  WritePBO := FPBOs[FPBOIndex];
  glBindBuffer(GL_PIXEL_PACK_BUFFER, WritePBO);
  glBindTexture(GL_TEXTURE_2D, FOutputTex);
  glGetTexImage(GL_TEXTURE_2D, 0, GL_BGRA, GL_UNSIGNED_BYTE, nil);
  glBindTexture(GL_TEXTURE_2D, 0);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

  FPBOIndex := FPBOIndex xor 1;
  FPBOHasData := True;

  ACanvas.Clear(TAlphaColors.Black);
  if Mapped <> nil then
  begin
    // Zero-copy path: draw directly from the still-mapped PBO pointer.
    // MakeFromRaster is lazy - it only dereferences Mapped during the
    // DrawImageRect call, so we MUST keep the PBO mapped until the draw
    // finishes. Upscale from sim resolution to the full view rect via
    // TSkSamplingOptions.Low (fast bilinear, no expensive mipmap / bikubich
    // filter on the iGPU so the fullscreen blit stays cheap).
    ImgInfo := TSkImageInfo.Create(FTexWidth, FTexHeight, TSkColorType.BGRA8888, TSkAlphaType.Premul);
    GPUImg := TSkImage.MakeFromRaster(ImgInfo, Mapped, FTexWidth * 4);
    if Assigned(GPUImg) then
      ACanvas.DrawImageRect(GPUImg, RectF(0, 0, FTexWidth, FTexHeight), RectF(0, 0, ViewW, ViewH), TSkSamplingOptions.Low);
    // Unmap AFTER the draw. glGetTexImage above re-bound the pack buffer to
    // WritePBO then 0, so re-bind ReadPBO here to unmap the right buffer.
    glBindBuffer(GL_PIXEL_PACK_BUFFER, ReadPBO);
    glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  end
  else if (FPixelBuffer <> nil) and (Length(FPixelBuffer) >= FTexWidth * FTexHeight * 4) then
  begin
    // Fallback: if the PBO mapping failed (rare driver hiccup / first
    // frame), fall back to the pre-allocated CPU buffer so the surface
    // never goes black on a transient mapping failure.
    ImgInfo := TSkImageInfo.Create(FTexWidth, FTexHeight, TSkColorType.BGRA8888, TSkAlphaType.Premul);
    GPUImg := TSkImage.MakeFromRaster(ImgInfo, Pointer(FPixelBuffer), FTexWidth * 4);
    if Assigned(GPUImg) then
      ACanvas.DrawImageRect(GPUImg, RectF(0, 0, FTexWidth, FTexHeight), RectF(0, 0, ViewW, ViewH), TSkSamplingOptions.Low);
  end;
end;

procedure TGPUAliveComponentHost.Resize;
begin
  inherited;
  if FGLReady and (Round(Width) > 1) and (Round(Height) > 1) then
  begin
    FGLLock.Enter;
    try
      FResizePending := True;
    finally
      FGLLock.Leave;
    end;
  end;
end;

{==============================================================================
  Constructor / destructor / properties
==============================================================================}
constructor TGPUAliveComponentHost.Create(AOwner: TComponent);
begin
  inherited;
  Width := 800;
  Height := 600;
  FGLReady := False;
  FGLFailed := False;
  FOutputTex := 0;
  FParticleSSBO := 0;
  FParticleCount := 0;
  FMaxParticles := PARTICLE_MAX;
  FBoundStart := 0;
  FBoundCount := 0;
  FAmbientCount := 0;
  FTexWidth := 0;
  FTexHeight := 0;
  FViewWidth := 0;
  FViewHeight := 0;
  FSimWidth := 0;
  FSimHeight := 0;
  FLocP_AmbientRatio := -1;
  FLocP_BtnClickFlash := -1;
  FLocP_DespawnRect := -1;
  FLocP_DespawnFade := -1;
  FLocP_FocusRect := -1;
  FLocP_FocusGlow := -1;
  FLocP_CursorRect := -1;
  FLocP_CursorBlink := -1;
  FLocP_UIStyle := -1;
  FAmbientDensity := 0.35;
  FTrailPersistence := 0.84;
  // Live-tunable effect parameter defaults.
  FSpringStiffness := 220.0;     // bound spring force (k)
  FHoverGlowStrength := 1.0;     // hover / LED-strip brightness
  FMouseRepelForce := 0.02;      // gentle rubber-like mouse nudge (no galaxy swirl)
  FSimResolutionScale := 1.0;    // full 1:1 sharpness everywhere (lower via slider if needed)
  FBackgroundEffect := pbeFlowField;
  FSpawnEffect := pseSwarmIn;
  FDespawnEffect := pdeExplodeOut;
  FMorphEffect := pmeCloudReform;
  FUIStyle := pusSolidFluid;
  FHoveredIndex := -1;
  FClickPulse := 0;
  FBtnClickFlash := 0;
  // pctEdit focus + caret blink defaults: no focus, caret starts in the
  // on-phase (so a freshly focused edit shows '|' immediately before the
  // first toggle), blink accumulator at 0.
  FFocusedIndex := -1;
  FCursorBlinkAccum := 0;
  FCursorOnPhase := True;
  FSpawnControlIdx := -1;
  FDespawnControlIdx := -1;
  FDespawnTimer := 0;
  FMouseX := -1;
  FMouseY := -1;
  FMouseDX := 0;
  FMouseDY := 0;
  FResizePending := False;
  FPBOHasData := False;
  FPBOIndex := 0;
  FPBOSize := 0;
  FPBOs[0] := 0;
  FPBOs[1] := 0;
  FGLLock := TCriticalSection.Create;
  FMouseLock := TCriticalSection.Create;
  FControlsLock := TCriticalSection.Create;
  FLayoutMaskLock := TCriticalSection.Create;
  HitTest := True;
  // 50 FPS target (not 60): 20 ms/frame instead of 16.6 ms gives the iGPU
  // ~3.4 ms of headroom per frame for compute + decay + PBO DMA + Skia blit,
  // which is often the difference between an occasional micro-stutter and a
  // perfectly even cadence in fullscreen. Exposed via TargetFPS so the user
  // can raise it to 60 on a discrete GPU.
  TargetFPS := 50;
end;

destructor TGPUAliveComponentHost.Destroy;
begin
  // ---- Clean OpenGL shutdown (fixes Intel-GPU crash, GitHub issue #1) ----
  // The render thread owns the offscreen GL context and issues GL calls every
  // frame. On Intel drivers, destroying the context / GL resources while the
  // render thread is still mid-frame corrupts the driver state and crashes the
  // process on close. So the order here is MANDATORY:
  //   1. Active := False  -> signals the render thread to stop its loop.
  //   2. inherited       -> the base class joins (waits for) the render thread
  //                         so it is guaranteed dead before we touch GL state.
  //   3. CleanupOffscreenGL -> now runs with no other thread touching GL; safe
  //                            to delete textures / PBOs / SSBOs / programs.
  // Steps 1 + 2 MUST run before step 3 - never reorder.
  Active := False;
  inherited;
  CleanupOffscreenGL;
  FreeAndNil(FGLLock);
  FreeAndNil(FMouseLock);
  FreeAndNil(FControlsLock);
  FreeAndNil(FLayoutMaskLock);
end;

procedure TGPUAliveComponentHost.SetAmbientDensity(const Value: Single);
var
  V: Single;
begin
  V := EnsureRange(Value, 0.0, 0.5);
  if Abs(V - FAmbientDensity) < 1e-4 then
    Exit;
  FAmbientDensity := V;
  // NO MarkLayoutDirty: the uAmbientRatio uniform drives the per-particle
  // ambient budget gate directly on the GPU, so toggling dust changes a
  // single float read by the render thread in DispatchComputeFrame and
  // never rebuilds the layout mask or re-uploads the SSBO. This removes
  // the CPU-side upload stutter that used to freeze the UI for a frame
  // every time "Toggle Dust" was clicked.
end;

procedure TGPUAliveComponentHost.SetTrailPersistence(const Value: Single);
begin
  FTrailPersistence := EnsureRange(Value, 0.70, 0.98);
end;

end.

