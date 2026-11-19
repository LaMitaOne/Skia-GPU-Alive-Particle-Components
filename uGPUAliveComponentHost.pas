unit uGPUAliveComponentHost;

{*******************************************************************************
  GPUAliveComponentHost  v0.1
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
    2. ResizeTextures() if the control size changed.
    3. RebuildLayoutMaskIfNeeded() if FLayoutDirty (after Add/Update
       of a virtual control): GDI paints the controls into a DIB,
       an alpha-fix marks only painted pixels as opaque, the mask is
       copied into FLayoutMask, particles are bound to mask pixels.
    4. Async PBO readback of the PREVIOUS frame into FPixelBuffer.
    5. Decay pass (compute): output texture is darkened (trail fade).
    6. Particle pass (compute): spring-damper + mouse + hover + click.
    7. glGetTexImage into the next PBO (async, no pipeline stall).
    8. Blit FPixelBuffer as a Skia raster image onto the base surface.

  ==============================================================================
  SSBO LAYOUT (32 bytes per particle, std430)
  ==============================================================================

    vec2 pos       (8B)  current position in UV space [0..1]^2
    vec2 vel       (8B)  velocity in UV/second
    vec2 homePos   (8B)  target UV, or (-1,-1) for ambient particles
    uint color     (4B)  packed as 0xRRGGBBAA
    uint flags     (4B)  0 = ambient (free floating)
                         1 = bound to a control (label/button/png)

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

    1. Ambient particle alpha is deliberately tiny (0.04) so free-
       floating dust adds almost nothing to the framebuffer.
    2. Bound particle alpha stays at 1.0 so buttons and text keep full
       contrast.
    3. The decay pass clamps the framebuffer at 0.85 brightness, so even
       a dense cloud of particles can never completely white out the
       background.

  If the whole surface starts looking too bright, lower FTrailDecay
  (0.72 is a good default; 0.65 gives an even darker look).

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
  TParticleControlType = (pctLabel, pctButton, pctPNG);

  TParticleClickEvent = procedure(Sender: TObject) of object;

  { One virtual control in the particle UI. Kept on the UI thread; the
    render thread only reads the composited BGRA mask plus per-control
    hover/visible state. }
  TParticleControl = record
    Name: string;
    CtlType: TParticleControlType;
    Bounds: TRect;             // window pixels, top-left origin
    Text: string;
    Color: Cardinal;           // packed 0xRRGGBBAA
    OnClick: TParticleClickEvent;
    BGRA: TBytes;              // for pctPNG: decoded BGRA bytes (ImgW*ImgH*4)
    ImgW: Integer;
    ImgH: Integer;
    Hovered: Boolean;
    Visible: Boolean;
    NeedsRebuild: Boolean;
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
    FParticleCount: Cardinal;
    FTexWidth: Integer;
    FTexHeight: Integer;

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
    FLocP_ParticleCount: Integer;
    FLocP_Time: Integer;
    FLocD_Resolution: Integer;
    FLocD_TrailDecay: Integer;

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

    { Virtual controls (UI thread owns the list, render thread reads via
      FControlsLock) }
    FControls: array of TParticleControl;
    FControlsLock: TCriticalSection;

    { Layout mask (BGRA, FTexWidth * FTexHeight * 4) }
    FLayoutMask: TBytes;
    FLayoutDirty: Boolean;
    FLayoutMaskLock: TCriticalSection;

    { Offscreen Win32 DIB used to rasterize virtual controls into the
      BGRA mask via pure GDI (no FMX canvas in the render thread). }
    FDIB: HBITMAP;
    FDIBDC: HDC;
    FDIBBits: Pointer;
    FDIBInfo: TBitmapInfo;

    { Configuration }
    FAmbientDensity: Single;
    FTrailDecay: Single;

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

    { Render-thread work }
    procedure DispatchComputeFrame(DeltaTime, TimeSec: Double);
    procedure DispatchDecayPass;
    procedure ApplyMouseStateUniforms;

    { Layout mask }
    procedure RebuildLayoutMaskIfNeeded;
    procedure RenderControlToCanvas(const ACtl: TParticleControl);
    procedure MarkLayoutDirty;

    { Particle reassignment }
    procedure ReassignParticlesFromMask;
    procedure SeedAmbientParticles(StartIdx, EndIdx: Integer);

    { Controls }
    function FindControlByName(const AName: string): Integer;

    { Setters }
    procedure SetAmbientDensity(const Value: Single);
    procedure SetTrailDecay(const Value: Single);
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
    procedure UpdateControlText(const AName, ANewText: string);
    procedure SetControlVisible(const AName: string; AVisible: Boolean);

    function HitTestButton(X, Y: Integer): Integer;

    property AmbientDensity: Single read FAmbientDensity write SetAmbientDensity;
    property TrailDecay: Single read FTrailDecay write SetTrailDecay;
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
  - A hovered button acts as a magnet for ambient particles, pulling
    them toward the button center.
  - A click pulses outward as an expanding ring shockwave.
  - Output is written into the image2D via imageLoad/imageStore.

  Decay shader:
  - Multiplies RGB by a per-frame trail factor, subtracts a small
    constant, and clamps the result at 0.85 so additive particle
    rendering can never fully white-out the background.
==============================================================================}
procedure TGPUAliveComponentHost.InitShaders;
const
  PARTICLE_SRC: AnsiString = '#version 430 core'#10 + 'layout(local_size_x = 64) in;'#10 + 'struct Particle {'#10 + '  vec2 pos;'#10 + '  vec2 vel;'#10 + '  vec2 homePos;'#10 + '  uint color;'#10 + '  uint flags;'#10 + '};'#10 + 'layout(binding = 0, std430) buffer ParticleSSBO {'#10 + '  Particle Particles[];'#10 + '};'#10 + 'layout(rgba8, binding = 0) uniform image2D uOutput;'#10 + 'uniform float uDeltaTime;'#10 + 'uniform float uTime;'#10 + 'uniform vec2  uResolution;'#10 + 'uniform vec2  uMousePos;'#10 +
    'uniform vec2  uMouseVel;'#10 + 'uniform vec4  uHoverRect;'#10 + 'uniform float uHoverGlow;'#10 + 'uniform float uClickPulse;'#10 + 'uniform vec2  uClickPos;'#10 + 'uniform uint  uParticleCount;'#10 + #10 + 'vec4 unpackCol(uint c){ return vec4(float((c>>16)&0xFF)/255.0, float((c>>8)&0xFF)/255.0, float(c&0xFF)/255.0, float((c>>24)&0xFF)/255.0); }'#10 + #10 + 'void main(){'#10 +
    // 2D dispatch index: the X axis alone caps at GL_MAX_COMPUTE_WORK_GROUP_COUNT
    // (65535), which limits 1D dispatch to ~4.19M particles at local_size 64.
    // The Y axis multiplies the addressable space so bigger windows work.
    '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 64u) + gl_GlobalInvocationID.x;'#10 + '  if (idx >= uParticleCount) return;'#10 + '  vec2 pos = Particles[idx].pos;'#10 + '  vec2 vel = Particles[idx].vel;'#10 + '  vec2 home = Particles[idx].homePos;'#10 + '  uint flags = Particles[idx].flags;'#10 + #10 + '  float dt = clamp(uDeltaTime, 0.0, 0.033);'#10 + #10 +
    // Physics: bound particles use a spring-damper toward homePos,
    // ambient particles drift with sine noise and wrap around edges.
    '  if (flags > 0u) {'#10 + '    vec2 d = home - pos;'#10 + '    float k = 220.0;'#10 + '    float c = 18.0;'#10 + '    vel += d * k * dt - vel * c * dt;'#10 + '    vel += vec2(sin(uTime*3.0 + float(idx)*0.13), cos(uTime*2.4 + float(idx)*0.21)) * 0.0008;'#10 + '  } else {'#10 + '    vel += vec2(sin(uTime*0.6 + float(idx)*0.07), cos(uTime*0.5 + float(idx)*0.05)) * 0.0015;'#10 + '    vel *= 0.985;'#10 + '    if (pos.x < -0.02) pos.x += 1.04;'#10 + '    if (pos.x >  1.02) pos.x -= 1.04;'#10 + '    if (pos.y < -0.02) pos.y += 1.04;'#10 + '    if (pos.y >  1.02) pos.y -= 1.04;'#10 + '  }'#10 + #10 +
    // Mouse force field: tangential (swirl) plus a gentle radial push.
    // Ambient particles are pushed harder than bound ones so buttons
    // stay intact while the background stirs.
    '  vec2 mUV = uMousePos / uResolution;'#10 + '  vec2 mVelUV = uMouseVel / uResolution;'#10 + '  if (mUV.x >= 0.0 && mUV.x <= 1.0 && mUV.y >= 0.0 && mUV.y <= 1.0) {'#10 + '    vec2 d = pos - mUV;'#10 + '    float dist = length(d) + 1e-5;'#10 + '    float influence = exp(-dist * 14.0);'#10 + '    vel += vec2(-d.y, d.x) * (mVelUV.x + mVelUV.y) * 0.6 * influence;'#10 + '    if (flags == 0u) {'#10 + '      vel += d / dist * influence * 0.15;'#10 + '    } else {'#10 + '      vel += d / dist * influence * 0.05;'#10 + '    }'#10 + '  }'#10 + #10 +
    // Hover magnet: ambient particles near a hovered button are pulled
    // toward its center, making the button attract dust.
    '  if (uHoverRect.x >= 0.0 && flags == 0u) {'#10 + '    vec2 hUV = uHoverRect.xy / uResolution;'#10 + '    vec2 hSize = uHoverRect.zw / uResolution;'#10 + '    vec2 center = hUV + hSize * 0.5;'#10 + '    vec2 d = center - pos;'#10 + '    float dist = length(d) + 1e-5;'#10 + '    float influence = exp(-dist * 8.0) * uHoverGlow;'#10 + '    vel += d / dist * influence * 0.6;'#10 + '  }'#10 + #10 +
    // Click shockwave: expanding ring impulse. Ring radius grows with
    // the click pulse, thickness is Gaussian around the ring.
    '  if (uClickPulse > 0.001) {'#10 + '    vec2 cUV = uClickPos / uResolution;'#10 + '    vec2 d = pos - cUV;'#10 + '    float dist = length(d) + 1e-5;'#10 + '    float ringRadius = uClickPulse * 0.5;'#10 + '    float ringThickness = 0.08;'#10 + '    float distToRing = abs(dist - ringRadius);'#10 + '    float ring = exp(-distToRing * distToRing / (2.0 * ringThickness * ringThickness));'#10 + '    vel += d / dist * ring * uClickPulse * 1.2;'#10 + '  }'#10 + #10 + '  pos += vel * dt;'#10 + '  Particles[idx].pos = pos;'#10 + '  Particles[idx].vel = vel;'#10 + #10 +
    // Additive write. Ambient particles contribute very little (0.04)
    // so the background stays dark; bound particles contribute fully
    // (1.0) so buttons/text keep full contrast.
    '  ivec2 px = ivec2(pos * uResolution);'#10 + '  if (px.x >= 0 && px.x < int(uResolution.x) && px.y >= 0 && px.y < int(uResolution.y)) {'#10 + '    vec4 col = unpackCol(Particles[idx].color);'#10 + '    float alpha = (flags == 0u) ? 0.04 : 1.0;'#10 + '    col.a = alpha;'#10 + '    vec4 existing = imageLoad(uOutput, px);'#10 + '    vec4 outc = clamp(existing + col * alpha, vec4(0.0), vec4(1.0));'#10 + '    outc.a = max(existing.a, alpha);'#10 + '    imageStore(uOutput, px, outc);'#10 + '  }'#10 + '}';
  DECAY_SRC: AnsiString = '#version 430 core'#10 + 'layout(local_size_x = 16, local_size_y = 16) in;'#10 + 'layout(rgba8, binding = 0) uniform image2D uOutput;'#10 + 'uniform vec2 uResolution;'#10 + 'uniform float uTrailDecay;'#10 + 'void main(){'#10 + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 + '  if (px.x >= int(uResolution.x) || px.y >= int(uResolution.y)) return;'#10 + '  vec4 c = imageLoad(uOutput, px);'#10 + '  c.rgb *= uTrailDecay;'#10 + '  c.rgb = max(c.rgb - 0.03, vec3(0.0));'#10 + '  c.a   = max(c.a   - 0.06, 0.0);'#10 +
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
    FLocP_ClickPulse := glGetUniformLocation(FParticleProgram, 'uClickPulse');
    FLocP_ClickPos := glGetUniformLocation(FParticleProgram, 'uClickPos');
    FLocP_ParticleCount := glGetUniformLocation(FParticleProgram, 'uParticleCount');
    FLocP_Time := glGetUniformLocation(FParticleProgram, 'uTime');
  end;
  if FDecayProgram <> 0 then
  begin
    glUseProgram(FDecayProgram);
    FLocD_Resolution := glGetUniformLocation(FDecayProgram, 'uResolution');
    FLocD_TrailDecay := glGetUniformLocation(FDecayProgram, 'uTrailDecay');
  end;
  glUseProgram(0);
end;

{==============================================================================
  GL resources: SSBO, output texture, FBO
==============================================================================}
procedure TGPUAliveComponentHost.InitGLResources;
var
  TotalPixels: Int64;
begin
  TotalPixels := Int64(Round(Width)) * Int64(Round(Height));
  if TotalPixels < 1 then
    TotalPixels := 1;
  FParticleCount := Cardinal(TotalPixels * 3 div 2);
  if FParticleCount > 2000000 then
    FParticleCount := 2000000;
  if FParticleCount < 1024 then
    FParticleCount := 1024;

  SetLength(FParticleCPU, NativeInt(FParticleCount) * 32);
  FillChar(Pointer(FParticleCPU)^, Length(FParticleCPU), 0);

  glGenBuffers(1, @FParticleSSBO);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
  glBufferData(GL_SHADER_STORAGE_BUFFER, NativeInt(FParticleCount) * 32, Pointer(FParticleCPU), GL_DYNAMIC_COPY);
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
begin
  if FParticleSSBO = 0 then
    Exit;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
  glBufferData(GL_SHADER_STORAGE_BUFFER, NativeInt(FParticleCount) * 32, Pointer(FParticleCPU), GL_DYNAMIC_COPY);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
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
  glUniform1f(FLocD_TrailDecay, FTrailDecay);
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
  CX, CY: Single;
  HoverIdx: Integer;
  HoverRect: array[0..3] of Single;
  HoverGlow: Single;
  Ctl: TParticleControl;
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
    CX := FClickX;
    CY := FClickY;
    HoverIdx := FHoveredIndex;
  finally
    FMouseLock.Leave;
  end;

  glUniform2f(FLocP_MousePos, MX, MY);
  glUniform2f(FLocP_MouseVel, MDX, MDY);

  if (HoverIdx >= 0) and (HoverIdx < Length(FControls)) then
  begin
    FControlsLock.Enter;
    try
      Ctl := FControls[HoverIdx];
    finally
      FControlsLock.Leave;
    end;
    HoverRect[0] := Ctl.Bounds.Left;
    HoverRect[1] := Ctl.Bounds.Top;
    HoverRect[2] := Ctl.Bounds.Right - Ctl.Bounds.Left;
    HoverRect[3] := Ctl.Bounds.Bottom - Ctl.Bounds.Top;
    HoverGlow := 1.0;
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
  glUniform2f(FLocP_ClickPos, CX, CY);
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

  TotalGroups := (Int64(FParticleCount) + 63) div 64;
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

procedure TGPUAliveComponentHost.RenderControlToCanvas(const ACtl: TParticleControl);
var
  R: TRect;
  BrushCol: COLORREF;
  Br: HBRUSH;
  TextLen: Integer;
  URect: TRect;
  BI: TBitmapInfo;
begin
  if (not ACtl.Visible) or (FDIBDC = 0) then
    Exit;
  R := ACtl.Bounds;

  // ACtl.Color is packed 0xRRGGBBAA. GDI wants COLORREF = 0x00BBGGRR.
  BrushCol := RGB(Byte((ACtl.Color shr 16) and $FF), Byte((ACtl.Color shr 8) and $FF), Byte((ACtl.Color shr 0) and $FF));

  case ACtl.CtlType of
    pctButton:
      begin
        // Filled rectangle: every pixel becomes opaque, so the button
        // becomes a dense particle rectangle.
        Br := CreateSolidBrush(BrushCol);
        FillRect(FDIBDC, R, Br);
        DeleteObject(Br);
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
  SelectObject(FDIBDC, GetStockObject(SYSTEM_FONT));
  URect := R;
  TextLen := Length(ACtl.Text);
  if TextLen > 0 then
    DrawText(FDIBDC, PChar(ACtl.Text), TextLen, URect, DT_CENTER or DT_VCENTER or DT_SINGLELINE);
end;

procedure TGPUAliveComponentHost.RebuildLayoutMaskIfNeeded;
var
  NeedReassign: Boolean;
  I: Integer;
  BmpW: Integer;
  Br: HBRUSH;
  Px: PCardinal;
  PixIdx: Integer;
begin
  FLayoutMaskLock.Enter;
  try
    NeedReassign := FLayoutDirty;
    FLayoutDirty := False;
  finally
    FLayoutMaskLock.Leave;
  end;
  if (not NeedReassign) or (FDIBDC = 0) then
    Exit;

  BmpW := FTexWidth;
  Br := CreateSolidBrush(RGB(0, 0, 0));
  FillRect(FDIBDC, Rect(0, 0, FTexWidth, FTexHeight), Br);
  DeleteObject(Br);

  FControlsLock.Enter;
  try
    for I := 0 to High(FControls) do
      if FControls[I].Visible then
        RenderControlToCanvas(FControls[I]);
  finally
    FControlsLock.Leave;
  end;

  // Alpha fix: only pixels that are NOT pure black are marked opaque.
  // This turns labels into text silhouettes (black rect + white text)
  // and keeps buttons/text fully opaque (they were filled with color).
  Px := PCardinal(FDIBBits);
  for PixIdx := 0 to (FTexWidth * FTexHeight) - 1 do
  begin
    if (Px^ and $00FFFFFF) = 0 then
      Px^ := 0                       // pure black -> background
    else
      Px^ := Px^ or $FF000000;       // anything else -> opaque
    Inc(Px);
  end;

  FLayoutMaskLock.Enter;
  try
    if Length(FLayoutMask) >= BmpW * FTexHeight * 4 then
      System.Move(FDIBBits^, Pointer(FLayoutMask)^, BmpW * FTexHeight * 4);
  finally
    FLayoutMaskLock.Leave;
  end;

  ReassignParticlesFromMask;
end;

{==============================================================================
  Particle reassignment

  Every opaque mask pixel becomes one bound particle at that position,
  with the mask pixel's color. The remaining particles are respawned as
  ambient dust.
==============================================================================}
procedure TGPUAliveComponentHost.ReassignParticlesFromMask;
var
  X, Y: Integer;
  Idx: Cardinal;
  PixelIdx: Cardinal;
  C: Cardinal;
  BoundMax: Cardinal;
  AmbientMax: Cardinal;
  P: PByte;
  TotalPixels: Cardinal;
  NonTransparentCount: Cardinal;
  DensityTarget: Cardinal;
begin
  if (FTexWidth <= 0) or (FTexHeight <= 0) or (FParticleCount = 0) then
    Exit;

  SeedAmbientParticles(Integer(FBoundCount), Integer(FParticleCount) - 1);

  AmbientMax := Cardinal(Round(FParticleCount * FAmbientDensity));
  BoundMax := FParticleCount - AmbientMax;

  TotalPixels := Cardinal(FTexWidth) * Cardinal(FTexHeight);
  NonTransparentCount := 0;
  for PixelIdx := 0 to TotalPixels - 1 do
  begin
    C := PCardinal(@FLayoutMask[PixelIdx * 4])^;
    if (C and $FF000000) <> 0 then
      Inc(NonTransparentCount);
  end;
  if NonTransparentCount = 0 then
  begin
    FBoundStart := 0;
    FBoundCount := 0;
    FAmbientCount := FParticleCount;
    SeedAmbientParticles(0, FParticleCount - 1);
    UploadSSBO;
    Exit;
  end;

  // One particle per opaque mask pixel. Buttons and text fill up
  // completely, no raster holes.
  DensityTarget := NonTransparentCount;
  if DensityTarget > BoundMax then
    DensityTarget := BoundMax;
  if DensityTarget < 1 then
    DensityTarget := 1;

  FBoundStart := 0;
  FBoundCount := 0;
  Idx := 0;

  for Y := 0 to FTexHeight - 1 do
  begin
    for X := 0 to FTexWidth - 1 do
    begin
      C := PCardinal(@FLayoutMask[(Y * FTexWidth + X) * 4])^;
      if (C and $FF000000) = 0 then
        Continue;
      if Idx >= DensityTarget then
        Break;
      P := @FParticleCPU[Idx * 32];
      PSingle(P + 0)^ := X / FTexWidth;
      PSingle(P + 4)^ := Y / FTexHeight;
      PSingle(P + 8)^ := 0;
      PSingle(P + 12)^ := 0;
      PSingle(P + 16)^ := X / FTexWidth;
      PSingle(P + 20)^ := Y / FTexHeight;
      // BGRA (GDI DIB) -> 0xRRGGBBAA (SSBO). Byte 0 of the DIB is blue,
      // byte 2 is red - swap them so colours come out right on screen.
      PCardinal(P + 24)^ := ((C and $00FF0000) shr 16) or       // red
        ((C and $0000FF00)) or              // green
        ((C and $000000FF) shl 16) or       // blue
        $FF000000;                          // alpha
      PCardinal(P + 28)^ := 1;              // flags = bound
      Inc(Idx);
    end;
    if Idx >= DensityTarget then
      Break;
  end;

  FBoundCount := Idx;
  FAmbientCount := FParticleCount - FBoundCount;
  SeedAmbientParticles(FBoundCount, FParticleCount - 1);
  UploadSSBO;
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
  Ctl.NeedsRebuild := True;
  FControlsLock.Enter;
  try
    Result := Length(FControls);
    SetLength(FControls, Result + 1);
    FControls[Result] := Ctl;
  finally
    FControlsLock.Leave;
  end;
  MarkLayoutDirty;
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
  Ctl.NeedsRebuild := True;
  FControlsLock.Enter;
  try
    Result := Length(FControls);
    SetLength(FControls, Result + 1);
    FControls[Result] := Ctl;
  finally
    FControlsLock.Leave;
  end;
  MarkLayoutDirty;
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
  Ctl.NeedsRebuild := True;
  FControlsLock.Enter;
  try
    Result := Length(FControls);
    SetLength(FControls, Result + 1);
    FControls[Result] := Ctl;
  finally
    FControlsLock.Leave;
  end;
  MarkLayoutDirty;
end;

procedure TGPUAliveComponentHost.UpdateControlText(const AName, ANewText: string);
var
  Idx: Integer;
begin
  FControlsLock.Enter;
  try
    Idx := FindControlByName(AName);
    if Idx < 0 then
      Exit;
    FControls[Idx].Text := ANewText;
    FControls[Idx].NeedsRebuild := True;
  finally
    FControlsLock.Leave;
  end;
  MarkLayoutDirty;
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
  Ctl: TParticleControl;
  Handler: TParticleClickEvent;
  Xi, Yi: Integer;
begin
  inherited;
  if Button <> TMouseButton.mbLeft then
    Exit;
  Xi := Round(X);
  Yi := Round(Y);
  FMouseLock.Enter;
  try
    FClickPulse := 1.0;
    FClickX := X;
    FClickY := Y;
  finally
    FMouseLock.Leave;
  end;
  BtnIdx := HitTestButton(Xi, Yi);
  if BtnIdx >= 0 then
  begin
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
    FTexWidth := Max(1, Round(Width));
    FTexHeight := Max(1, Round(Height));
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
  NewW, NewH: Integer;
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

  FGLLock.Enter;
  try
    NeedResize := FResizePending;
    FResizePending := False;
    NewW := Round(Width);
    NewH := Round(Height);
  finally
    FGLLock.Leave;
  end;
  if NeedResize and (NewW > 1) and (NewH > 1) then
    ResizeTextures(NewW, NewH);

  RebuildLayoutMaskIfNeeded;

  // Async readback of the PREVIOUS frame's PBO. The glGetTexImage for
  // this PBO was issued one frame ago and the GPU DMA has been running
  // in the background since then.
  if FPBOHasData then
  begin
    ReadPBO := FPBOs[FPBOIndex xor 1];
    glBindBuffer(GL_PIXEL_PACK_BUFFER, ReadPBO);
    Mapped := glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, FPBOSize, GL_MAP_READ_BIT);
    if Mapped <> nil then
    begin
      System.Move(Mapped^, Pointer(FPixelBuffer)^, FPBOSize);
      glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    end;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
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
  if (FPixelBuffer <> nil) and (Length(FPixelBuffer) >= FTexWidth * FTexHeight * 4) then
  begin
    ImgInfo := TSkImageInfo.Create(FTexWidth, FTexHeight, TSkColorType.BGRA8888, TSkAlphaType.Premul);
    GPUImg := TSkImage.MakeFromRaster(ImgInfo, Pointer(FPixelBuffer), FTexWidth * 4);
    if Assigned(GPUImg) then
      ACanvas.DrawImageRect(GPUImg, RectF(0, 0, FTexWidth, FTexHeight), RectF(0, 0, ViewW, ViewH), TSkSamplingOptions.Medium);
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
  FBoundStart := 0;
  FBoundCount := 0;
  FAmbientCount := 0;
  FTexWidth := 0;
  FTexHeight := 0;
  FAmbientDensity := 0.25;
  FTrailDecay := 0.82;
  FHoveredIndex := -1;
  FClickPulse := 0;
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
end;

destructor TGPUAliveComponentHost.Destroy;
begin
  Active := False;
  // IMPORTANT: inherited first. It calls StopThread and joins the render
  // thread, so the UI thread can safely delete the GL context afterwards.
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
  MarkLayoutDirty;
end;

procedure TGPUAliveComponentHost.SetTrailDecay(const Value: Single);
begin
  FTrailDecay := EnsureRange(Value, 0.70, 0.98);
end;

end.

