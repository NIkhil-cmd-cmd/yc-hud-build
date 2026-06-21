import { LiquidMetal } from "@paper-design/shaders-react";

/**
 * Liquid Logo — @paper-design/shaders-react LiquidMetal (WebGL/GLSL).
 * Uses the Tera wordmark SVG for edge-aware liquid metal distortion.
 */
export function LiquidLogo({ width = 108, height = 40, className = "" }) {
  return (
    <div className={`liquid-logo ${className}`} style={{ width, height }}>
      <LiquidMetal
        image="/assets/wordmark.svg"
        width={width}
        height={height}
        fit="contain"
        colorBack="#00000000"
        colorTint="#1a1a1a"
        repetition={5}
        softness={0.35}
        distortion={0.18}
        shiftRed={0.02}
        shiftBlue={-0.03}
        speed={0.22}
        scale={1}
      />
    </div>
  );
}
