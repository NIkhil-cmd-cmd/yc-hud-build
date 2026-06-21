import { ShaderGradientCanvas, ShaderGradient } from "@shadergradient/react";

const BASE =
  "animate=on&axesHelper=off&embedMode=off&envPreset=city&grain=on&lightType=3d&rotation=0&shader=defaults&wireframe=false&uAmplitude=0";

/** Dark hero base — slow waterPlane, warm charcoal + amber */
export const HERO_GRADIENT = `https://www.shadergradient.co/customize?${BASE}&brightness=0.72&cAzimuthAngle=170&cDistance=5.4&cPolarAngle=88&cameraZoom=1&color1=%23090909&color2=%23181816&color3=%23352822&grainBlending=0.48&pixelDensity=1.5&positionY=0.1&reflection=0.18&type=waterPlane&uDensity=1&uFrequency=4.2&uSpeed=0.18&uStrength=2.4`;

/** Teal accent orb — top right */
export const HERO_ACCENT_TEAL = `https://www.shadergradient.co/customize?${BASE}&brightness=0.85&cAzimuthAngle=210&cDistance=4.2&cPolarAngle=72&cameraZoom=1.1&color1=%23000000&color2=%23081210&color3=%2312a884&grainBlending=0.52&pixelDensity=1.2&positionY=-0.05&reflection=0.22&type=plane&uDensity=1.1&uFrequency=5.4&uSpeed=0.28&uStrength=3.1`;

/** Amber whisper — bottom left */
export const HERO_ACCENT_AMBER = `https://www.shadergradient.co/customize?${BASE}&brightness=0.78&cAzimuthAngle=140&cDistance=3.8&cPolarAngle=82&cameraZoom=1&color1=%23000000&color2=%231a140e&color3=%23c4a484&grainBlending=0.55&pixelDensity=1.2&positionY=0.15&reflection=0.2&type=waterPlane&uDensity=0.95&uFrequency=3.8&uSpeed=0.14&uStrength=2.8`;

/** Deep violet depth — center drift */
export const HERO_ACCENT_VIOLET = `https://www.shadergradient.co/customize?${BASE}&brightness=0.62&cAzimuthAngle=190&cDistance=6.2&cPolarAngle=90&cameraZoom=1&color1=%23070707&color2=%23101018&color3=%235c4a8a&grainBlending=0.44&pixelDensity=1.1&positionY=0&reflection=0.12&type=plane&uDensity=0.88&uFrequency=4.8&uSpeed=0.2&uStrength=2.2`;

/** Testimonials — flat plane, deep charcoal */
export const TESTIMONIALS_GRADIENT = `https://www.shadergradient.co/customize?${BASE}&brightness=0.55&cAzimuthAngle=180&cDistance=7&cPolarAngle=90&cameraZoom=1&color1=%23070707&color2=%23111111&color3=%231a1a18&grainBlending=0.38&pixelDensity=1.2&positionY=0&reflection=0.08&type=plane&uDensity=0.85&uFrequency=3.2&uSpeed=0.1&uStrength=1.6`;

/** @deprecated use TESTIMONIALS_GRADIENT */
export const DARK_GRADIENT = TESTIMONIALS_GRADIENT;

export function ShaderBackground({
  urlString = HERO_GRADIENT,
  className = "",
  pixelDensity = 1.5,
  fov,
  variant = "hero",
  lazyLoad = true,
  threshold = 0.05,
}) {
  const resolvedFov = fov ?? (variant === "testimonials" ? 50 : 45);

  return (
    <div className={`shader-bg shader-bg--${variant} ${className}`.trim()} aria-hidden="true">
      <ShaderGradientCanvas
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
        pixelDensity={pixelDensity}
        fov={resolvedFov}
        pointerEvents="none"
        lazyLoad={lazyLoad}
        threshold={threshold}
      >
        <ShaderGradient control="query" urlString={urlString} />
      </ShaderGradientCanvas>
      {variant !== "hero-accent" && variant !== "hero-stack" ? (
        <>
          <div className="shader-bg-vignette" />
          <div className="shader-bg-fallback" />
        </>
      ) : null}
    </div>
  );
}

/** Layered hero — base + three accent ShaderGradients with scroll parallax */
export function HeroShaderBackground() {
  return (
    <div className="hero-shader-stack" aria-hidden="true">
      <ShaderBackground
        urlString={HERO_GRADIENT}
        className="hero-shader-layer hero-shader-layer--base"
        variant="hero-stack"
        pixelDensity={1.6}
        lazyLoad={false}
      />
      <ShaderBackground
        urlString={HERO_ACCENT_TEAL}
        className="hero-shader-layer hero-shader-layer--teal"
        variant="hero-accent"
        pixelDensity={1.15}
        fov={52}
        threshold={0}
      />
      <ShaderBackground
        urlString={HERO_ACCENT_AMBER}
        className="hero-shader-layer hero-shader-layer--amber"
        variant="hero-accent"
        pixelDensity={1.15}
        fov={48}
        threshold={0}
      />
      <ShaderBackground
        urlString={HERO_ACCENT_VIOLET}
        className="hero-shader-layer hero-shader-layer--violet"
        variant="hero-accent"
        pixelDensity={1.05}
        fov={55}
        threshold={0}
      />
      <div className="hero-shader-vignette" />
      <div className="hero-shader-fade" />
    </div>
  );
}
