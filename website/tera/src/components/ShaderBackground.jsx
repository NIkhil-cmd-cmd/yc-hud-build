import { ShaderGradientCanvas, ShaderGradient } from "@shadergradient/react";

/** Dark hero — slow waterPlane, warm charcoal + amber whisper, heavy grain */
export const HERO_GRADIENT =
  "https://www.shadergradient.co/customize?animate=on&axesHelper=off&brightness=0.72&cAzimuthAngle=170&cDistance=5.4&cPolarAngle=88&cameraZoom=1&color1=%23090909&color2=%23181816&color3=%23352822&embedMode=off&envPreset=city&grain=on&grainBlending=0.48&lightType=3d&pixelDensity=1.5&positionY=0.1&reflection=0.18&rotation=0&shader=defaults&type=waterPlane&uAmplitude=0&uDensity=1&uFrequency=4.2&uSpeed=0.18&uStrength=2.4&wireframe=false";

/** Testimonials — flat plane, no sphere blob; deep charcoal only */
export const TESTIMONIALS_GRADIENT =
  "https://www.shadergradient.co/customize?animate=on&axesHelper=off&brightness=0.55&cAzimuthAngle=180&cDistance=7&cPolarAngle=90&cameraZoom=1&color1=%23070707&color2=%23111111&color3=%231a1a18&embedMode=off&envPreset=city&grain=on&grainBlending=0.38&lightType=3d&pixelDensity=1.2&positionY=0&reflection=0.08&rotation=0&shader=defaults&type=plane&uAmplitude=0&uDensity=0.85&uFrequency=3.2&uSpeed=0.1&uStrength=1.6&wireframe=false";

/** @deprecated use TESTIMONIALS_GRADIENT */
export const DARK_GRADIENT = TESTIMONIALS_GRADIENT;

export function ShaderBackground({
  urlString = HERO_GRADIENT,
  className = "",
  pixelDensity = 1.5,
  variant = "hero",
}) {
  return (
    <div className={`shader-bg shader-bg--${variant} ${className}`} aria-hidden="true">
      <ShaderGradientCanvas
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
        pixelDensity={pixelDensity}
        fov={variant === "testimonials" ? 50 : 45}
        pointerEvents="none"
        lazyLoad
        threshold={0.05}
      >
        <ShaderGradient control="query" urlString={urlString} />
      </ShaderGradientCanvas>
      <div className="shader-bg-vignette" />
      <div className="shader-bg-fallback" />
    </div>
  );
}
