unit Unit1;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.IOUtils,
  System.Skia,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  uGPUAliveComponentHost;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    FHost: TGPUAliveComponentHost;
    FMorphState: Integer;
    procedure DoMorphButtonClick(Sender: TObject);
    procedure DoDensityToggleClick(Sender: TObject);
    procedure LoadAndAddParticlePNG(const AFileName, AControlName: string; X, Y, W, H: Integer);
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

procedure TForm1.LoadAndAddParticlePNG(const AFileName, AControlName: string; X, Y, W, H: Integer);
var
  FullPath: string;
  Img: ISkImage;
  Info: TSkImageInfo;
  Bytes: TBytes;
begin
  FullPath := TPath.Combine(ExtractFilePath(ParamStr(0)), AFileName);
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
  Caption := 'GPU Alive Component Particle UI Host - PoC';
  ClientWidth := 900;
  ClientHeight := 600;
  Fill.Color := TAlphaColorRec.Black;

  FMorphState := 0;

  FHost := TGPUAliveComponentHost.Create(Self);
  FHost.Parent := Self;
  FHost.Align := TAlignLayout.Client;
  FHost.AmbientDensity := 0.20;
  FHost.TrailDecay := 0.82;
  FHost.TargetFPS := 45;

  FHost.AddParticleLabel('Morph', 300, 80, 300, 64, 'PARTICLES', $FF682818);
  FHost.AddParticleButton('BtnMorph', 300, 200, 300, 56, 'Morph Label', $FF221858, DoMorphButtonClick);
  FHost.AddParticleButton('BtnDensity', 300, 280, 300, 56, 'Toggle Dust', $FF504006, DoDensityToggleClick);

  LoadAndAddParticlePNG('logo.png', 'LogoPNG', 640, 160, 180, 180);

  FHost.InitGL;
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
    FHost.AmbientDensity := 0.35
  else
    FHost.AmbientDensity := 0.20;
end;

end.

