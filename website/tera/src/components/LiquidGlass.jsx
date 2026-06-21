import { useId } from "react";

/**
 * Liquid Glass — SVG feTurbulence + feDisplacementMap lensing,
 * combined with backdrop-filter refraction (WWDC25-style material).
 */
export function LiquidGlass({
  children,
  className = "",
  as: Tag = "div",
  intensity = 1,
  blur = 22,
  ...props
}) {
  const id = useId().replace(/:/g, "");
  const turbulenceId = `lg-turb-${id}`;
  const displacementId = `lg-disp-${id}`;
  const specularId = `lg-spec-${id}`;

  return (
    <>
      <svg className="liquid-glass-svg-defs" aria-hidden="true">
        <defs>
          <filter id={turbulenceId} x="0%" y="0%" width="100%" height="100%">
            <feTurbulence
              type="fractalNoise"
              baseFrequency="0.014 0.018"
              numOctaves="4"
              seed="12"
              stitchTiles="stitch"
              result="noise"
            />
            <feColorMatrix in="noise" type="saturate" values="0" result="mono" />
          </filter>
          <filter id={displacementId} x="-15%" y="-15%" width="130%" height="130%" colorInterpolationFilters="sRGB">
            <feTurbulence
              type="fractalNoise"
              baseFrequency="0.006 0.009"
              numOctaves="3"
              seed="4"
              result="warp"
            />
            <feDisplacementMap
              in="SourceGraphic"
              in2="warp"
              scale={10 * intensity}
              xChannelSelector="R"
              yChannelSelector="G"
            />
          </filter>
          <linearGradient id={specularId} x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stopColor="rgba(255,255,255,0.55)" />
            <stop offset="45%" stopColor="rgba(255,255,255,0.08)" />
            <stop offset="100%" stopColor="rgba(255,255,255,0.22)" />
          </linearGradient>
        </defs>
      </svg>
      <Tag
        className={`liquid-glass ${className}`}
        style={{
          "--lg-blur": `${blur}px`,
          "--lg-turbulence": `url(#${turbulenceId})`,
          "--lg-displacement": `url(#${displacementId})`,
          "--lg-specular": `url(#${specularId})`,
        }}
        {...props}
      >
        <span className="liquid-glass-backdrop" aria-hidden="true" />
        <span className="liquid-glass-noise" aria-hidden="true" />
        <span className="liquid-glass-specular" aria-hidden="true" />
        <span className="liquid-glass-content">{children}</span>
      </Tag>
    </>
  );
}
