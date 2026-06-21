import { GrainGradient } from "@paper-design/shaders-react";

const PALETTES = [
  ["#fafaf8", "#e8ddd0", "#c4a484"],
  ["#f5f2ec", "#d9cfc4", "#b8a898"],
  ["#ece8e2", "#d4c8ba", "#a69480"],
  ["#f0ede8", "#e0d5c8", "#c17d3a"],
];

/** Noisy grain-gradient card art — @paper-design/shaders-react */
export function GrainCardArt({ index = 0, className = "" }) {
  const colors = PALETTES[index % PALETTES.length];
  return (
    <div className={`grain-card-art ${className}`}>
      <GrainGradient
        width="100%"
        height="100%"
        colors={colors}
        colorBack="#fafaf8"
        softness={0.65}
        intensity={0.55}
        noise={0.75}
        shape="wave"
        speed={0.15 + index * 0.04}
        scale={1.1}
        fit="cover"
      />
    </div>
  );
}
