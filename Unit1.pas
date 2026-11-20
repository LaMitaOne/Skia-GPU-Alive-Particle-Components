unit Unit1;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.Skia, Winapi.Windows,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Edit, FMX.ListBox, FMX.Objects, FMX.Layouts,
  uGPUAliveComponentHost;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
  protected
    { KeyDown override catches the H key to toggle the sandbox bar without
      needing KeyPreview. Click the particle area first so no TEdit holds
      focus, then press H. }
    procedure KeyDown(var Key: Word; var KeyChar: Char; Shift: TShiftState); override;
    { FormCloseQuery: stop the render thread BEFORE the window handle is
      destroyed so the GL context is never torn down mid-frame (Intel-GPU
      crash on close, GitHub issue #1). }
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  private
    FHost: TGPUAliveComponentHost;
    FMorphState: Integer;
    FSandboxPanel: TRectangle;
    FSandboxScroll: TVertScrollBox;
    FSandboxVisible: Boolean;
    // Sandbox edit fields: [0]=X, [1]=Y, [2]=W, [3]=H
    FSandboxEdits: array[0..3] of TEdit;
    FSandboxList: TListBox;
    FSpawnCounter: Integer;
    // Live value labels next to each slider (updated in OnChange).
    FLblFPS, FLblDust, FLblTrail, FLblSpring, FLblHover, FLblMouse, FLblSim: TLabel;
    procedure DoMorphButtonClick(Sender: TObject);
    procedure DoDensityToggleClick(Sender: TObject);
    procedure LoadAndAddParticlePNG(const AFileName, AControlName: string; X, Y, W, H: Integer);
    { Sandbox bar }
    procedure BuildSandboxBar;
    procedure DoSpawnButtonClick(Sender: TObject);
    procedure DoSpawnLabelClick(Sender: TObject);
    procedure DoSpawnPNGClick(Sender: TObject);
    procedure DoSpawnEditClick(Sender: TObject);
    { pctEdit OnChange: live-updates the big particle label (index 0) while
      typing into the EditMain particle input field. }
    procedure DoParticleEditChange(Sender: TObject);
    procedure DoRemoveSelectedClick(Sender: TObject);
    procedure RefreshControlList;
    function GetSpawnParam(AIndex: Integer; ADefault: Integer): Integer;
    procedure AdvanceSpawnY;
    { Slider + combo change handlers }
    procedure DoFPSChange(Sender: TObject);
    procedure DoDustChange(Sender: TObject);
    procedure DoTrailChange(Sender: TObject);
    procedure DoSpringChange(Sender: TObject);
    procedure DoHoverChange(Sender: TObject);
    procedure DoMouseChange(Sender: TObject);
    procedure DoSimChange(Sender: TObject);
    procedure DoBgFXChange(Sender: TObject);
    procedure DoSpawnFXChange(Sender: TObject);
    procedure DoDespawnFXChange(Sender: TObject);
    procedure DoMorphFXChange(Sender: TObject);
    procedure DoUIStyleChange(Sender: TObject);
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

{ Standalone helpers that build a slider / combo row inside the scroll box.
  Defined here (unit level) so BuildSandboxBar can compose the tall settings
  stack without a giant inline sequence. }

function AddSliderRow(AParent: TFmxObject; var Y: Integer; const ACaption: string;
  AMin, AMax, AFreq, AValue: Single): TTrackBar;
var
  Lbl: TLabel;
  Tb: TTrackBar;
begin
  Lbl := TLabel.Create(AParent);
  Lbl.Parent := AParent;
  Lbl.Text := ACaption;
  Lbl.StyledSettings := [];
  Lbl.TextSettings.FontColor := TAlphaColors.Lightgray;
  Lbl.TextSettings.Font.Size := 11;
  Lbl.Position.X := 0;
  Lbl.Position.Y := Y;
  Lbl.Width := 240;
  Lbl.Height := 16;

  Tb := TTrackBar.Create(AParent);
  Tb.Parent := AParent;
  Tb.Min := AMin;
  Tb.Max := AMax;
  Tb.Frequency := AFreq;
  Tb.Value := AValue;
  Tb.Position.X := 0;
  Tb.Position.Y := Y + 18;
  Tb.Width := 240;
  Tb.Height := 26;

  Y := Y + 48;
  Result := Tb;
end;

function AddComboRow(AParent: TFmxObject; var Y: Integer; const ACaption: string;
  const AItems: array of string): TComboBox;
var
  Lbl: TLabel;
  Cb: TComboBox;
  I: Integer;
begin
  Lbl := TLabel.Create(AParent);
  Lbl.Parent := AParent;
  Lbl.Text := ACaption;
  Lbl.StyledSettings := [];
  Lbl.TextSettings.FontColor := TAlphaColors.Lightgray;
  Lbl.TextSettings.Font.Size := 11;
  Lbl.Position.X := 0;
  Lbl.Position.Y := Y;
  Lbl.Width := 240;
  Lbl.Height := 16;

  Cb := TComboBox.Create(AParent);
  Cb.Parent := AParent;
  Cb.Position.X := 0;
  Cb.Position.Y := Y + 18;
  Cb.Width := 240;
  Cb.Height := 24;
  for I := 0 to High(AItems) do
    Cb.Items.Add(AItems[I]);
  Cb.ItemIndex := 0;

  Y := Y + 48;
  Result := Cb;
end;

{ Helper: a small value label placed at the top-right of the slider row that
  was just added (Y already advanced past it, so anchor 44 px above Y). }
function AddValueLabel(AParent: TFmxObject; Y: Integer; const AText: string): TLabel;
begin
  Result := TLabel.Create(AParent);
  Result.Parent := AParent;
  Result.StyledSettings := [];
  Result.TextSettings.FontColor := TAlphaColors.Lemonchiffon;
  Result.TextSettings.Font.Size := 11;
  Result.Position.X := 184;
  Result.Position.Y := Y - 44;
  Result.Width := 56;
  Result.Height := 16;
  Result.Text := AText;
  Result.TextAlign := TTextAlign.Trailing;
end;

procedure TForm1.LoadAndAddParticlePNG(const AFileName, AControlName: string; X, Y, W, H: Integer);
var
  FullPath: string;
  Img: ISkImage;
  Info: TSkImageInfo;
  Bytes: TBytes;
begin
  // FMX rule: build the asset path with IncludeTrailingPathDelimiter, never
  // TPath.Combine / System.IOUtils (which drags in platform path deps that
  // break on some targets). ParamStr(0) dir + the bare file name.
  FullPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + AFileName;
  if not FileExists(FullPath) then
    Exit;

  Img := TSkImage.MakeFromEncodedFile(FullPath);
  if not Assigned(Img) then
    Exit;

  Info := TSkImageInfo.Create(Img.Width, Img.Height, TSkColorType.BGRA8888, TSkAlphaType.Premul);
  SetLength(Bytes, Img.Width * Img.Height * 4);

  if Img.ReadPixels(Info, @Bytes[0], Img.Width * 4, 0, 0) then
    FHost.AddParticlePNG(AControlName, X, Y, W, H, Bytes, Img.Width, Img.Height);
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  Caption := 'GPU Alive Component Particle UI Host - Sandbox (H toggles bar)';
  // NOTE: ClientWidth / ClientHeight are intentionally NOT set here so the
  // size chosen in the form designer (.fmx) is preserved.
  Fill.Color := TAlphaColorRec.Black;

  FMorphState := 0;
  FSpawnCounter := 0;
  FSandboxVisible := True;

  FHost := TGPUAliveComponentHost.Create(Self);
  FHost.Parent := Self;
  FHost.Align := TAlignLayout.Client;
  FHost.AmbientDensity := 0.35;
  FHost.TrailPersistence := 0.84;
  FHost.TargetFPS := 50;

  // Colours use standard FMX TAlphaColors (0xAARRGGBB). RenderControlToCanvas
  // extracts R/G/B from the upper three bytes and the slot reassign copies
  // the mask pixel straight through to the SSBO (no R/B swap).
  FHost.AddParticleLabel('Morph', 300, 80, 300, 64, 'PARTICLES', TAlphaColors.Crimson);
  FHost.AddParticleButton('BtnMorph', 300, 200, 300, 56, 'Morph Label', TAlphaColors.Indigo, DoMorphButtonClick);
  FHost.AddParticleButton('BtnDensity', 300, 280, 300, 56, 'Toggle Dust', TAlphaColors.Teal, DoDensityToggleClick);

  // Particle input field (pctEdit): a dark rounded field with a fine lighter
  // rim + a blinking '|' caret made of real particles. Click it to focus,
  // then type - each keystroke reflows the text smoothly (gentle morph, no
  // explosion) and fires DoParticleEditChange, which mirrors the typed text
  // into the big 'Morph' label above so the label updates LIVE while typing.
  FHost.AddParticleEdit('EditMain', 'Type here...', 300, 360, 300, 46, $FF1E293B, DoParticleEditChange);

  // logo.png placed to the RIGHT of the buttons (X=630) so it does not
  // overlap them; Y=80 aligns it with the label row.
  LoadAndAddParticlePNG('logo.png', 'LogoPNG', 630, 80, 180, 180);

  FHost.InitGL;

  BuildSandboxBar;

  // Wire the close-query handler so the render thread is stopped before the
  // window handle (and its GL context) is destroyed (Intel-GPU crash fix).
  OnCloseQuery := FormCloseQuery;
end;

procedure TForm1.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // Stop the render thread FIRST, then allow the form to close. The host's
  // destructor re-asserts Active := False, but setting it here guarantees the
  // thread is idle before FMX tears down the window handle / GL context.
  if FHost <> nil then
    FHost.Active := False;
  CanClose := True;
  TerminateProcess(GetCurrentProcess, 0);
end;

procedure TForm1.KeyDown(var Key: Word; var KeyChar: Char; Shift: TShiftState);
begin
  inherited;
  // Route keystrokes to a focused particle edit FIRST. If a pctEdit is
  // focused, HandleKeyInput either appends / deletes a character (and
  // swallows Key + KeyChar so the 'H' sandbox toggle below does not also
  // fire while typing 'h'/'H') or - for non-printable keys - leaves them
  // untouched. If no edit is focused it is a no-op and Key/KeyChar pass
  // through unchanged. Note: in FMX Char = WideChar, so the var KeyChar
  // maps straight onto HandleKeyInput's WideChar parameter.
  if FHost <> nil then
    FHost.HandleKeyInput(Key, KeyChar);
  if (KeyChar = 'h') or (KeyChar = 'H') then
  begin
    FSandboxVisible := not FSandboxVisible;
    if FSandboxPanel <> nil then
      FSandboxPanel.Visible := FSandboxVisible;
    KeyChar := #0;
  end;
end;

procedure TForm1.BuildSandboxBar;
const
  EDIT_LABELS: array[0..3] of string = ('X:', 'Y:', 'W:', 'H:');
  EDIT_DEFAULTS: array[0..3] of string = ('80', '320', '220', '46');
var
  Panel: TRectangle;
  Scroll: TVertScrollBox;
  TitleLbl, EdtLbl, ListLbl, SecLbl: TLabel;
  Edt: TEdit;
  BtnSpawnBtn, BtnSpawnLbl, BtnSpawnPNG, BtnSpawnEdit, BtnRemove: TButton;
  Lst: TListBox;
  Tb: TTrackBar;
  Cb: TComboBox;
  I: Integer;
  Y: Integer;
begin
  Panel := TRectangle.Create(Self);
  Panel.Parent := Self;
  Panel.Name := 'SandboxPanel';
  Panel.Align := TAlignLayout.Right;
  Panel.Width := 260;
  Panel.Fill.Color := $FF181820;
  Panel.Stroke.Kind := TBrushKind.None;
  Panel.ClipChildren := True;

  // TVertScrollBox holds all controls so the tall stack (edits + spawns +
  // list + 7 sliders + 4 combos) scrolls vertically instead of overflowing.
  Scroll := TVertScrollBox.Create(Panel);
  Scroll.Parent := Panel;
  Scroll.Align := TAlignLayout.Client;
  Scroll.Padding.Rect := RectF(8, 8, 8, 8);
  FSandboxScroll := Scroll;

  // Title
  TitleLbl := TLabel.Create(Scroll);
  TitleLbl.Parent := Scroll;
  TitleLbl.Text := 'Sandbox (H)';
  TitleLbl.StyledSettings := [];
  TitleLbl.TextSettings.FontColor := TAlphaColors.White;
  TitleLbl.TextSettings.Font.Size := 14;
  TitleLbl.Position.X := 0;
  TitleLbl.Position.Y := 0;
  TitleLbl.Width := 240;
  TitleLbl.Height := 22;

  // 4 edit rows: X / Y / W / H
  Y := 30;
  for I := 0 to 3 do
  begin
    EdtLbl := TLabel.Create(Scroll);
    EdtLbl.Parent := Scroll;
    EdtLbl.Text := EDIT_LABELS[I];
    EdtLbl.StyledSettings := [];
    EdtLbl.TextSettings.FontColor := TAlphaColors.Lightgray;
    EdtLbl.TextSettings.Font.Size := 12;
    EdtLbl.Position.X := 4;
    EdtLbl.Position.Y := Y + 3;
    EdtLbl.Width := 24;
    EdtLbl.Height := 20;

    Edt := TEdit.Create(Scroll);
    Edt.Parent := Scroll;
    Edt.Text := EDIT_DEFAULTS[I];
    Edt.Position.X := 32;
    Edt.Position.Y := Y;
    Edt.Width := 208;
    Edt.Height := 24;
    Edt.StyledSettings := [];
    Edt.TextSettings.Font.Size := 12;
    FSandboxEdits[I] := Edt;

    Y := Y + 30;
  end;

  // Spawn buttons
  BtnSpawnBtn := TButton.Create(Scroll);
  BtnSpawnBtn.Parent := Scroll;
  BtnSpawnBtn.Text := 'Spawn Button';
  BtnSpawnBtn.Position.X := 0;
  BtnSpawnBtn.Position.Y := Y + 4;
  BtnSpawnBtn.Width := 240;
  BtnSpawnBtn.Height := 28;
  BtnSpawnBtn.OnClick := DoSpawnButtonClick;

  BtnSpawnLbl := TButton.Create(Scroll);
  BtnSpawnLbl.Parent := Scroll;
  BtnSpawnLbl.Text := 'Spawn Label';
  BtnSpawnLbl.Position.X := 0;
  BtnSpawnLbl.Position.Y := Y + 36;
  BtnSpawnLbl.Width := 240;
  BtnSpawnLbl.Height := 28;
  BtnSpawnLbl.OnClick := DoSpawnLabelClick;

  BtnSpawnPNG := TButton.Create(Scroll);
  BtnSpawnPNG.Parent := Scroll;
  BtnSpawnPNG.Text := 'Spawn PNG';
  BtnSpawnPNG.Position.X := 0;
  BtnSpawnPNG.Position.Y := Y + 68;
  BtnSpawnPNG.Width := 240;
  BtnSpawnPNG.Height := 28;
  BtnSpawnPNG.OnClick := DoSpawnPNGClick;

  BtnSpawnEdit := TButton.Create(Scroll);
  BtnSpawnEdit.Parent := Scroll;
  BtnSpawnEdit.Text := 'Spawn Edit';
  BtnSpawnEdit.Position.X := 0;
  BtnSpawnEdit.Position.Y := Y + 100;
  BtnSpawnEdit.Width := 240;
  BtnSpawnEdit.Height := 28;
  BtnSpawnEdit.OnClick := DoSpawnEditClick;

  Y := Y + 134;

  // Controls list
  ListLbl := TLabel.Create(Scroll);
  ListLbl.Parent := Scroll;
  ListLbl.Text := 'Controls:';
  ListLbl.StyledSettings := [];
  ListLbl.TextSettings.FontColor := TAlphaColors.Lightgray;
  ListLbl.TextSettings.Font.Size := 12;
  ListLbl.Position.X := 0;
  ListLbl.Position.Y := Y;
  ListLbl.Width := 240;
  ListLbl.Height := 18;

  Lst := TListBox.Create(Scroll);
  Lst.Parent := Scroll;
  Lst.Position.X := 0;
  Lst.Position.Y := Y + 20;
  Lst.Width := 240;
  Lst.Height := 110;
  FSandboxList := Lst;

  BtnRemove := TButton.Create(Scroll);
  BtnRemove.Parent := Scroll;
  BtnRemove.Text := 'Remove Selected';
  BtnRemove.Position.X := 0;
  BtnRemove.Position.Y := Y + 134;
  BtnRemove.Width := 240;
  BtnRemove.Height := 28;
  BtnRemove.OnClick := DoRemoveSelectedClick;

  Y := Y + 172;

  // --- Live settings section ---
  SecLbl := TLabel.Create(Scroll);
  SecLbl.Parent := Scroll;
  SecLbl.Text := '--- Live Settings ---';
  SecLbl.StyledSettings := [];
  SecLbl.TextSettings.FontColor := TAlphaColors.White;
  SecLbl.TextSettings.Font.Size := 12;
  SecLbl.Position.X := 0;
  SecLbl.Position.Y := Y;
  SecLbl.Width := 240;
  SecLbl.Height := 18;
  Y := Y + 22;

  // Target FPS (10..120)
  Tb := AddSliderRow(Scroll, Y, 'Target FPS', 10, 120, 1, 50);
  Tb.OnChange := DoFPSChange;
  FLblFPS := AddValueLabel(Scroll, Y, '50');

  // Background Dust (AmbientDensity 0..0.5 -> 0..50)
  Tb := AddSliderRow(Scroll, Y, 'Background Dust', 0, 50, 1, 35);
  Tb.OnChange := DoDustChange;
  FLblDust := AddValueLabel(Scroll, Y, '0.35');

  // Trail Length (TrailPersistence 0.70..0.98 -> 70..98)
  Tb := AddSliderRow(Scroll, Y, 'Trail Length', 70, 98, 1, 84);
  Tb.OnChange := DoTrailChange;
  FLblTrail := AddValueLabel(Scroll, Y, '0.84');

  // Spring Stiffness (50..500)
  Tb := AddSliderRow(Scroll, Y, 'Spring Stiffness', 50, 500, 5, 220);
  Tb.OnChange := DoSpringChange;
  FLblSpring := AddValueLabel(Scroll, Y, '220');

  // Hover Glow (0..3 -> 0..30)
  Tb := AddSliderRow(Scroll, Y, 'Hover Glow', 0, 30, 1, 10);
  Tb.OnChange := DoHoverChange;
  FLblHover := AddValueLabel(Scroll, Y, '1.0');

  // Mouse Force (0..0.5 -> 0..50), default 0.02 = gentle rubber nudge
  Tb := AddSliderRow(Scroll, Y, 'Mouse Force', 0, 50, 1, 2);
  Tb.OnChange := DoMouseChange;
  FLblMouse := AddValueLabel(Scroll, Y, '0.02');

  // Sim Scale (0.25..1.0 -> 25..100), default 1.00 = full 1:1 sharpness
  Tb := AddSliderRow(Scroll, Y, 'Sim Scale', 25, 100, 1, 100);
  Tb.OnChange := DoSimChange;
  FLblSim := AddValueLabel(Scroll, Y, '1.00');

  // --- Effect type section ---
  SecLbl := TLabel.Create(Scroll);
  SecLbl.Parent := Scroll;
  SecLbl.Text := '--- Effect Types ---';
  SecLbl.StyledSettings := [];
  SecLbl.TextSettings.FontColor := TAlphaColors.White;
  SecLbl.TextSettings.Font.Size := 12;
  SecLbl.Position.X := 0;
  SecLbl.Position.Y := Y;
  SecLbl.Width := 240;
  SecLbl.Height := 18;
  Y := Y + 22;

  Cb := AddComboRow(Scroll, Y, 'Background FX', ['FlowField', 'Vortex', 'Embers', 'None']);
  Cb.OnChange := DoBgFXChange;

  Cb := AddComboRow(Scroll, Y, 'Spawn FX', ['SwarmIn', 'Implode', 'RiseUp', 'Instant']);
  Cb.OnChange := DoSpawnFXChange;

  Cb := AddComboRow(Scroll, Y, 'Despawn FX', ['ExplodeOut', 'DissolveUp', 'VortexSuck', 'Instant']);
  Cb.OnChange := DoDespawnFXChange;

  Cb := AddComboRow(Scroll, Y, 'Morph FX', ['CloudReform', 'ScatterSnap', 'WaveSweep', 'Instant']);
  Cb.OnChange := DoMorphFXChange;

  // Visual UI style (SolidFluid / Holographic) - switches the bound
  // particle render look live via FHost.UIStyle (forwarded to the shader as
  // uUIStyle). Instant, no mask rebuild.
  Cb := AddComboRow(Scroll, Y, 'UI Style', ['SolidFluid', 'Holographic']);
  Cb.OnChange := DoUIStyleChange;

  FSandboxPanel := Panel;
  RefreshControlList;
end;

function TForm1.GetSpawnParam(AIndex: Integer; ADefault: Integer): Integer;
var
  S: string;
  V: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FSandboxEdits)) or (FSandboxEdits[AIndex] = nil) then
    Exit(ADefault);
  S := Trim(FSandboxEdits[AIndex].Text);
  if not TryStrToInt(S, V) then
    Exit(ADefault);
  Result := V;
end;

procedure TForm1.AdvanceSpawnY;
var
  YVal: Integer;
begin
  YVal := GetSpawnParam(1, 320) + 60;
  if (FHost <> nil) and (YVal > Round(FHost.Height) - 60) then
    YVal := 40;
  FSandboxEdits[1].Text := IntToStr(YVal);
end;

procedure TForm1.DoSpawnButtonClick(Sender: TObject);
var
  X, Yp, W, H: Integer;
  Name: string;
  Palette: array[0..4] of TAlphaColor;
begin
  X := GetSpawnParam(0, 80);
  Yp := GetSpawnParam(1, 320);
  W := GetSpawnParam(2, 220);
  H := GetSpawnParam(3, 46);
  Inc(FSpawnCounter);
  Name := 'SpawnedBtn' + IntToStr(FSpawnCounter);
  Palette[0] := TAlphaColors.Dodgerblue;
  Palette[1] := TAlphaColors.Seagreen;
  Palette[2] := TAlphaColors.Darkorange;
  Palette[3] := TAlphaColors.Mediumorchid;
  Palette[4] := TAlphaColors.Firebrick;
  FHost.AddParticleButton(Name, X, Yp, W, H, 'Button ' + IntToStr(FSpawnCounter),
    Palette[(FSpawnCounter - 1) mod Length(Palette)], nil);
  AdvanceSpawnY;
  RefreshControlList;
end;

procedure TForm1.DoSpawnLabelClick(Sender: TObject);
var
  X, Yp, W, H: Integer;
  Name: string;
  Palette: array[0..3] of TAlphaColor;
begin
  X := GetSpawnParam(0, 80);
  Yp := GetSpawnParam(1, 320);
  W := GetSpawnParam(2, 220);
  H := GetSpawnParam(3, 46);
  Inc(FSpawnCounter);
  Name := 'SpawnedLbl' + IntToStr(FSpawnCounter);
  Palette[0] := TAlphaColors.Gold;
  Palette[1] := TAlphaColors.Aquamarine;
  Palette[2] := TAlphaColors.Hotpink;
  Palette[3] := TAlphaColors.Lemonchiffon;
  FHost.AddParticleLabel(Name, X, Yp, W, H, 'Label ' + IntToStr(FSpawnCounter),
    Palette[(FSpawnCounter - 1) mod Length(Palette)]);
  AdvanceSpawnY;
  RefreshControlList;
end;

procedure TForm1.DoSpawnPNGClick(Sender: TObject);
var
  X, Yp, W, H: Integer;
  Name: string;
begin
  X := GetSpawnParam(0, 80);
  Yp := GetSpawnParam(1, 320);
  W := GetSpawnParam(2, 220);
  H := GetSpawnParam(3, 46);
  Inc(FSpawnCounter);
  Name := 'SpawnedPNG' + IntToStr(FSpawnCounter);
  LoadAndAddParticlePNG('logo.png', Name, X, Yp, W, H);
  AdvanceSpawnY;
  RefreshControlList;
end;

procedure TForm1.DoSpawnEditClick(Sender: TObject);
var
  X, Yp, W, H: Integer;
  Name: string;
  Palette: array[0..3] of TAlphaColor;
begin
  X := GetSpawnParam(0, 80);
  Yp := GetSpawnParam(1, 320);
  W := GetSpawnParam(2, 220);
  H := GetSpawnParam(3, 46);
  Inc(FSpawnCounter);
  Name := 'SpawnedEdit' + IntToStr(FSpawnCounter);
  // Dark field fills so the white caption + blinking '|' caret read clearly.
  Palette[0] := $FF1E293B;  // slate-900
  Palette[1] := $FF312E81;  // indigo-900
  Palette[2] := $FF1F3A3A;  // deep teal
  Palette[3] := $FF2D1B2E;  // dark plum
  FHost.AddParticleEdit(Name, 'edit...', X, Yp, W, H,
    Palette[(FSpawnCounter - 1) mod Length(Palette)], nil);
  AdvanceSpawnY;
  RefreshControlList;
end;

procedure TForm1.DoParticleEditChange(Sender: TObject);
var
  Txt: string;
begin
  // Mirror the EditMain particle input field's text into the big 'Morph'
  // label (index 0) so the label updates LIVE while typing. Gentle morph so
  // the label reflows smoothly on each keystroke instead of exploding.
  Txt := FHost.GetControlText('EditMain');
  if Txt = '' then
    Txt := ' ';
  FHost.UpdateControlText('Morph', Txt, True);
end;

procedure TForm1.DoRemoveSelectedClick(Sender: TObject);
var
  Idx: Integer;
begin
  if FSandboxList = nil then
    Exit;
  Idx := FSandboxList.ItemIndex;
  if Idx < 0 then
    Exit;
  // Mark the control as despawning - it keeps fading out on the canvas over
  // DESPAWN_DURATION (0.45 s) before TickDespawn removes it from FControls.
  FHost.RemoveParticleControl(Idx);
  // Remove the list entry IMMEDIATELY so it vanishes from the ListBox on
  // click, while the control still flies apart on the canvas. We must NOT call
  // RefreshControlList here: it rebuilds the list from FControls, which still
  // holds the despawning control during the fade, so it would re-add the entry
  // we just deleted. FControls ordering is preserved during the fade, so the
  // ListBox stays consistent with the eventual post-despawn FControls state.
  if Idx < FSandboxList.Items.Count then
    FSandboxList.Items.Delete(Idx);
  FSandboxList.ItemIndex := -1;
end;

procedure TForm1.RefreshControlList;
var
  I, N: Integer;
begin
  if (FSandboxList = nil) or (FHost = nil) then
    Exit;
  FSandboxList.BeginUpdate;
  try
    FSandboxList.Items.Clear;
    N := FHost.GetControlCount;
    for I := 0 to N - 1 do
      FSandboxList.Items.Add(FHost.GetControlDisplay(I));
  finally
    FSandboxList.EndUpdate;
  end;
end;

procedure TForm1.DoMorphButtonClick(Sender: TObject);
const
  WORDS: array[0..3] of string = ('PARTICLES', 'LIVING UI', 'COMPUTE', 'ZERO COPY');
begin
  FMorphState := (FMorphState + 1) mod Length(WORDS);
  FHost.UpdateControlText('Morph', WORDS[FMorphState]);
end;

procedure TForm1.DoDensityToggleClick(Sender: TObject);
begin
  if FHost.AmbientDensity < 0.30 then
    FHost.AmbientDensity := 0.45
  else
    FHost.AmbientDensity := 0.05;
end;

{--- Slider change handlers ---}
procedure TForm1.DoFPSChange(Sender: TObject);
begin
  FHost.TargetFPS := Round((Sender as TTrackBar).Value);
  if FLblFPS <> nil then
    FLblFPS.Text := IntToStr(FHost.TargetFPS);
end;

procedure TForm1.DoDustChange(Sender: TObject);
begin
  FHost.AmbientDensity := (Sender as TTrackBar).Value / 100.0;
  if FLblDust <> nil then
    FLblDust.Text := Format('%.2f', [FHost.AmbientDensity]);
end;

procedure TForm1.DoTrailChange(Sender: TObject);
begin
  FHost.TrailPersistence := (Sender as TTrackBar).Value / 100.0;
  if FLblTrail <> nil then
    FLblTrail.Text := Format('%.2f', [FHost.TrailPersistence]);
end;

procedure TForm1.DoSpringChange(Sender: TObject);
begin
  FHost.SpringStiffness := (Sender as TTrackBar).Value;
  if FLblSpring <> nil then
    FLblSpring.Text := IntToStr(Round(FHost.SpringStiffness));
end;

procedure TForm1.DoHoverChange(Sender: TObject);
begin
  FHost.HoverGlowStrength := (Sender as TTrackBar).Value / 10.0;
  if FLblHover <> nil then
    FLblHover.Text := Format('%.1f', [FHost.HoverGlowStrength]);
end;

procedure TForm1.DoMouseChange(Sender: TObject);
begin
  FHost.MouseRepelForce := (Sender as TTrackBar).Value / 100.0;
  if FLblMouse <> nil then
    FLblMouse.Text := Format('%.2f', [FHost.MouseRepelForce]);
end;

procedure TForm1.DoSimChange(Sender: TObject);
begin
  FHost.SimResolutionScale := (Sender as TTrackBar).Value / 100.0;
  if FLblSim <> nil then
    FLblSim.Text := Format('%.2f', [FHost.SimResolutionScale]);
end;

{--- Combo change handlers ---}
procedure TForm1.DoBgFXChange(Sender: TObject);
begin
  FHost.BackgroundEffect := TParticleBackgroundEffect((Sender as TComboBox).ItemIndex);
end;

procedure TForm1.DoSpawnFXChange(Sender: TObject);
begin
  FHost.SpawnEffect := TParticleSpawnEffect((Sender as TComboBox).ItemIndex);
end;

procedure TForm1.DoDespawnFXChange(Sender: TObject);
begin
  FHost.DespawnEffect := TParticleDespawnEffect((Sender as TComboBox).ItemIndex);
end;

procedure TForm1.DoMorphFXChange(Sender: TObject);
begin
  FHost.MorphEffect := TParticleMorphEffect((Sender as TComboBox).ItemIndex);
end;

procedure TForm1.DoUIStyleChange(Sender: TObject);
begin
  // Live-switch the bound particle render look (SolidFluid / Holographic).
  // Forwarded to the shader as uUIStyle every frame - instant.
  FHost.UIStyle := TParticleUIStyle((Sender as TComboBox).ItemIndex);
end;

end.
