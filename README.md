# Skia-GPUAliveParticleComponents (v0.1 PoC)

GPU-accelerated, physics-driven particle UI components powered by **Skia4Delphi** and **OpenGL Compute Shaders**.

Think of it as the GPU compute evolution of [Skia-AliveGrid](https://github.com/LaMitaOne/Skia-AliveGrid) — instead of simulating a few hundred particles on the CPU, UI controls themselves are formed out of hundreds of thousands (or millions) of interactive GPU particles.     

> **Status: v0.1 – Early Proof of Concept**  
> Right now this is an experimental first build ("the laptop didn't catch fire" edition). APIs will change, things might still be rough around the edges, and more components are planned down the road.
    
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Skia-GPU-Alive-Particle-Components)    
      
<img height="400" alt="Unbenannt" src="https://github.com/user-attachments/assets/c1fd063c-d5b0-43c6-99e7-11f50ae195a6" />
 
## The Idea

Standard UI controls are static rectangles. **GPUAliveParticleComponents** turns buttons, labels, and containers into living particle fields that react in real time to mouse movement, hover forces, clicks, and text/layout morphing — while keeping the CPU cool.

## What's Included in v0.1

* **`TGPUAliveComponentHost`**: The main GPU particle host container managing the offscreen OpenGL 4.3+ compute pipeline, PBO readback, and threaded Skia rendering.
* **Particle Labels & Buttons**: Basic interactive controls (`AddParticleLabel`, `AddParticleButton`) rendered directly as dynamic particle anchors.
* **Real-Time Mouse Physics**: Interactive repulsion / vortex forces that disturb particles on hover and smoothly pull them back into shape.
* **Dynamic Morphing**: Smooth particle transitions when changing label captions or toggling ambient dust density.

## Requirements

* **Delphi** (tested on modern Delphi VCL + Skia4Delphi)
* **[Skia4Delphi](https://github.com)**
* A GPU & driver supporting **OpenGL 4.3+** (Compute Shaders & SSBOs)

## Quick Example

```pascal
FHost := TGPUAliveComponentHost.Create(Self);
FHost.Parent := Self;
FHost.Align := alClient;

FHost.AddParticleLabel('Morph', 300, 80, 300, 64, 'PARTICLES', \$FF504006);
FHost.AddParticleButton('BtnMorph', 300, 200, 300, 56, 'Morph Label', \$FF682818, DoMorphClick);
FHost.AddParticleButton('BtnDensity', 300, 280, 300, 56, 'Toggle Dust', \$FF382A22, DoDensityClick);

FHost.InitGL;
```
     
Zipped exe and sample project included     
     
## License

MIT License – feel free to test, break things, and experiment.
