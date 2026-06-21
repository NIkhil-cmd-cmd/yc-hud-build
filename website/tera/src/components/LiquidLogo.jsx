import { LiquidMetal } from "@paper-design/shaders-react";

/**
 * Liquid Logo — @paper-design/shaders-react LiquidMetal (WebGL/GLSL).
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
        colorTint="#f5f2ec"
        repetition={5}
        softness={0.4}
        distortion={0.14}
        shiftRed={0.02}
        shiftBlue={-0.03}
        speed={0.18}
        scale={1}
      />
    </div>
  );
}
