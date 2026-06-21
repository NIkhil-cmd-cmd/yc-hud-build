import { GrainGradient } from "@paper-design/shaders-react";

const PALETTES = [
  ["#141414", "#1f1f1c", "#3d3428"],
  ["#111110", "#252320", "#4a3f32"],
  ["#0f0f0e", "#1a1917", "#2a2620"],
  ["#121212", "#222018", "#5c4a30"],
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
        colorBack="#090909"
        softness={0.7}
        intensity={0.45}
        noise={0.82}
        shape="wave"
        speed={0.12 + index * 0.03}
        scale={1.1}
        fit="cover"
      />
    </div>
  );
}
