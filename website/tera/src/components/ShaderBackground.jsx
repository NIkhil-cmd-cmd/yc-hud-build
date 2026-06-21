import { ShaderGradientCanvas, ShaderGradient } from "@shadergradient/react";

/** Tera palette — warm studio tones, grain on, waterPlane shader */
export const HERO_GRADIENT =
  "https://www.shadergradient.co/customize?animate=on&axesHelper=off&brightness=1.15&cAzimuthAngle=180&cDistance=4.1&cPolarAngle=86&cameraZoom=1&color1=%23FAFAF8&color2=%23E8DDD0&color3=%23C4A484&embedMode=off&envPreset=dawn&grain=on&grainBlending=0.42&lightType=3d&pixelDensity=1.6&positionY=0.15&reflection=0.38&rotation=0&shader=defaults&type=waterPlane&uAmplitude=0&uDensity=1.15&uFrequency=6.2&uSpeed=0.32&uStrength=3.4&wireframe=false";

export const DARK_GRADIENT =
  "https://www.shadergradient.co/customize?animate=on&axesHelper=off&brightness=0.85&cAzimuthAngle=200&cDistance=5.2&cPolarAngle=110&cameraZoom=1&color1=%23141414&color2=%232A2420&color3=%23C4A484&embedMode=off&envPreset=city&grain=on&grainBlending=0.55&lightType=3d&pixelDensity=1.4&positionY=-0.1&reflection=0.25&rotation=0&shader=defaults&type=sphere&uAmplitude=0&uDensity=1.3&uFrequency=4.8&uSpeed=0.22&uStrength=2.8&wireframe=false";

export function ShaderBackground({ urlString = HERO_GRADIENT, className = "", pixelDensity = 1.6 }) {
  return (
    <div className={`shader-bg ${className}`} aria-hidden="true">
      <ShaderGradientCanvas
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
        pixelDensity={pixelDensity}
        fov={45}
        pointerEvents="none"
        lazyLoad
        threshold={0.05}
      >
        <ShaderGradient control="query" urlString={urlString} />
      </ShaderGradientCanvas>
      <div className="shader-bg-vignette" />
    </div>
  );
}
