# Skia-GPU Alive Particle Components (v0.2 Prototype)
       
GPU-accelerated, physics-driven particle UI components powered by **Skia4Delphi** and **OpenGL Compute Shaders**.  
       
Think of it as the GPU compute evolution of [Skia-AliveGrid](https://github.com/LaMitaOne/Skia-AliveGrid) — instead of simulating a few hundred particles on the CPU, UI controls themselves are formed out of hundreds of thousands (or millions) of interactive GPU particles.  
       
> **Status: v0.2 – Interactive Prototype & Live Sandbox**  
> Now featuring interactive particle text inputs (`AddParticleEdit`), PNG particle decomposition, switchable UI & effect styles (`SolidFluid` / `Holographic`), zero-copy PBO transfers, and a built-in live sandbox panel. APIs are still evolving as more controls are added.         
       
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Skia-GPU-Alive-Particle-Components)         
      
<img width="1161" height="829" alt="Unbenannt" src="https://github.com/user-attachments/assets/c4dfd20b-ef98-486f-8178-de6fdb4adf82" />
       
Sample Video (v0.1): https://www.youtube.com/watch?v=1mzdYyLKNJs  
       
## The Idea       
       
Standard UI controls are static rectangles. **GPUAliveParticleComponents** turns labels, buttons, text inputs, and images into living particle fields that react in real time to mouse movement, flashlight hover glow, click light-runners, spawn/despawn explosions, and live text morphing — all driven on the GPU via OpenGL 4.3+ Compute Shaders.  
       
## What's Included in v0.2       
       
* **`TGPUAliveComponentHost`**: Offscreen OpenGL 4.3+ compute pipeline with isolated per-control particle slots, zero-copy PBO readback (`TSkImage.MakeFromRaster`), and multi-threaded Skia rendering.  
* **Interactive Particle Controls**:  
  * `AddParticleLabel` — Dynamic particle text with smooth or explosive cloud morphing (`UpdateControlText`).  
  * `AddParticleButton` — Rounded particle buttons with soft rubber hover deformation and an animated LED-strip light runner on click.  
  * `AddParticleEdit` — Clickable particle text box with focus border, shader-driven blinking caret, live keyboard input, and `OnChange` events.  
  * `AddParticlePNG` — Decomposes arbitrary RGBA images/logos into colored particle clusters.  
* **Switchable UI & Effect Styles**: Toggle live between `SolidFluid` and `Holographic` UI styles, plus extensible `Background`, `Spawn`, `Despawn`, and `Morph` effect modes.  
* **Cursor Flashlight & Rubber Physics**: Soft local glow around the mouse cursor and fluid tangential displacement without tearing controls apart.  
* **Built-In Live Sandbox (`H` toggles bar)**: Spawn/remove controls at runtime and tweak `Target FPS`, `Background Dust`, `Trail Length`, `Spring Stiffness`, `Hover Glow`, `Mouse Force`, and `Sim Scale` in real time.  
       
## Requirements       
       
* **Delphi** (tested on modern Delphi FMX/VCL + Skia4Delphi)  
* **[Skia4Delphi](https://github.com)**  
* A GPU & driver supporting **OpenGL 4.3+** (Compute Shaders & SSBOs)  
       
## Quick Example       
       
```pascal
FHost := TGPUAliveComponentHost.Create(Self);
FHost.Parent := Self;
FHost.Align := TAlignLayout.Client;

FHost.AddParticleLabel('Morph', 300, 80, 300, 64, 'PARTICLES', TAlphaColors.White);
FHost.AddParticleButton('BtnMorph', 300, 200, 300, 56, 'Morph Label', TAlphaColors.Indigo, DoMorphClick);
FHost.AddParticleButton('BtnDensity', 300, 280, 300, 56, 'Toggle Dust', TAlphaColors.Teal, DoDensityClick);
FHost.AddParticleEdit('EditMain', 'Hello Particle World', 300, 360, 300, 46, \$FF1E293B, DoEditChange);
FHost.AddParticlePNG('LogoPNG', 630, 80, 180, 180, PngBytes, PngWidth, PngHeight);

FHost.InitGL;
```
       
## Changelog       
       
### v0.2       
* **Interactive Particle Edit (`pctEdit`)**: Added `AddParticleEdit` with focus detection, shader-rendered blinking caret (zero control jitter), instant typing/backspace updates, and `OnChange` support.  
* **UI Styles & Extensible Effect Types**: Added `TParticleUIStyle` (`pusSolidFluid`, `pusHolographic`) alongside modular `Background`, `Spawn`, `Despawn`, and `Morph` effect enums.  
* **Live Sandbox Panel**: Added runtime control spawning/removal (`Button`, `Label`, `PNG`, `Edit`) and real-time sliders for all physics and rendering parameters (toggleable with `H`).  
* **Visual & Shader Upgrades**: Replaced harsh hover explosion with soft rubber displacement, local cursor flashlight glow, rounded button corners, crisp TrueType font rendering, and an animated perimeter LED-strip click effect.  
* **Performance & Stability**: Switched to zero-copy PBO-to-Skia mapping, isolated per-control particle slots (so morphing one label never disturbs other controls or PNGs), and fixed clean OpenGL context shutdown on exit (fixes #1 on Intel GPUs).  
       
### v0.1       
* Initial Proof of Concept with `TGPUAliveComponentHost`, basic particle labels/buttons, mouse repulsion, and label morphing.  
       
---       
       
Zipped exe and sample project included.         
       
## License       
       
MIT License – feel free to test, break things, and experiment.       
      
And nobody wants to know, but yes — it runs smooth on my fanless Asus UX305ca too @ ~40% CPU, ~30% GPU oO  
*Where no UX305CA has ever gone before* :D  

