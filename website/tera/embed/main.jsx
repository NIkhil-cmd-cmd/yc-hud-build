import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { ShaderGradientCanvas, ShaderGradient } from "@shadergradient/react";

const DEFAULT_GRADIENT =
  "https://www.shadergradient.co/customize?animate=on&axesHelper=off&brightness=0.72&cAzimuthAngle=170&cDistance=5.4&cPolarAngle=88&cameraZoom=1&color1=%23090909&color2=%23181816&color3=%23352822&embedMode=off&enableTransition=on&envPreset=city&grain=on&grainBlending=0.48&lightType=3d&pixelDensity=1.5&positionY=0.1&reflection=0.18&rotation=0&shader=defaults&type=waterPlane&uAmplitude=0&uDensity=1&uFrequency=4.2&uSpeed=0.18&uStrength=2.4&wireframe=false";

function readInitialGradient() {
  const params = new URLSearchParams(window.location.search);
  return params.get("gradient") || DEFAULT_GRADIENT;
}

function ShaderHost() {
  const [urlString, setUrlString] = useState(readInitialGradient);

  useEffect(() => {
    window.setGradientURL = (next) => {
      if (typeof next === "string" && next.length > 0) {
        setUrlString(next);
      }
    };
    return () => {
      delete window.setGradientURL;
    };
  }, []);

  return (
    <ShaderGradientCanvas
      style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }}
      pixelDensity={1.5}
      fov={45}
      pointerEvents="none"
    >
      <ShaderGradient control="query" urlString={urlString} />
    </ShaderGradientCanvas>
  );
}

createRoot(document.getElementById("root")).render(<ShaderHost />);
