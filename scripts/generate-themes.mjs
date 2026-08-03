import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const outputDirectory = path.join(scriptDirectory, "..", "Resources", "Themes");

const palettes = {
  graphite: {
    name: "Graphite",
    colors: {
      background: "#081016",
      surface: "#13212B",
      primaryText: "#EDF7F7",
      mutedText: "#89A2A7",
      accent: "#55E6D0",
      working: "#52B8FF",
      waitingApproval: "#FFC857",
      waitingInput: "#FF8AD8",
      compacting: "#A892FF",
      completed: "#42E58A",
      failed: "#FF627D",
      interrupted: "#FF8C69",
      idle: "#89A2A7",
    },
    shadow: "#020608",
  },
  ocean: {
    name: "Ocean",
    colors: {
      background: "#031925",
      surface: "#073348",
      primaryText: "#E8FBFF",
      mutedText: "#81ADBB",
      accent: "#37D9ED",
      working: "#57A9FF",
      waitingApproval: "#FFD166",
      waitingInput: "#F4A8FF",
      compacting: "#9E9BFF",
      completed: "#4DE3A1",
      failed: "#FF6B7A",
      interrupted: "#FF9D76",
      idle: "#81ADBB",
    },
    shadow: "#011017",
  },
  terminalGreen: {
    name: "Terminal Green",
    colors: {
      background: "#020704",
      surface: "#07150C",
      primaryText: "#B9FFD0",
      mutedText: "#62A878",
      accent: "#54FF8A",
      working: "#82FFB0",
      waitingApproval: "#E8FF6A",
      waitingInput: "#9DFFDF",
      compacting: "#B0FF96",
      completed: "#35F27A",
      failed: "#FF667D",
      interrupted: "#FFAD66",
      idle: "#62A878",
    },
    shadow: "#010302",
  },
  sunset: {
    name: "Sunset",
    colors: {
      background: "#1A0B1D",
      surface: "#342035",
      primaryText: "#FFF1E9",
      mutedText: "#C49AAF",
      accent: "#FF9A62",
      working: "#A892FF",
      waitingApproval: "#FFD166",
      waitingInput: "#FF91C8",
      compacting: "#C89CFF",
      completed: "#6EE7A8",
      failed: "#FF5B77",
      interrupted: "#FFAA73",
      idle: "#C49AAF",
    },
    shadow: "#0D050F",
  },
  highContrast: {
    name: "High Contrast",
    colors: {
      background: "#000000",
      surface: "#111111",
      primaryText: "#FFFFFF",
      mutedText: "#D0D0D0",
      accent: "#00FFFF",
      working: "#66B3FF",
      waitingApproval: "#FFFF00",
      waitingInput: "#FF66FF",
      compacting: "#CC99FF",
      completed: "#00FF66",
      failed: "#FF3355",
      interrupted: "#FF9900",
      idle: "#D0D0D0",
    },
    shadow: "#000000",
  },
};

const families = {
  nativeGlass: {
    typography: { family: "SF Pro Rounded", sizeScale: 1, weight: "medium", lineHeight: 1.2 },
    cornerRadius: 24,
    border: { width: 1, style: "solid" },
    shadow: { x: 0, y: 12, blur: 30, opacity: 0.3 },
    noise: 0.03,
    blur: "regular",
    collapsedOpacity: 0.72,
    expandedOpacity: 0.88,
    animation: { enabled: true, durationMs: 180, easing: "easeOut" },
  },
  retroTerminal: {
    typography: { family: "SF Mono", sizeScale: 0.96, weight: "medium", lineHeight: 1.1 },
    cornerRadius: 10,
    border: { width: 1, style: "solid" },
    shadow: { x: 0, y: 6, blur: 16, opacity: 0.4 },
    noise: 0.08,
    blur: "thin",
    collapsedOpacity: 0.86,
    expandedOpacity: 0.94,
    animation: { enabled: true, durationMs: 120, easing: "linear" },
  },
  minimalOLED: {
    typography: { family: "SF Pro Text", sizeScale: 1, weight: "regular", lineHeight: 1.2 },
    cornerRadius: 18,
    border: { width: 0, style: "none" },
    shadow: { x: 0, y: 0, blur: 0, opacity: 0 },
    noise: 0,
    blur: "off",
    collapsedOpacity: 1,
    expandedOpacity: 1,
    animation: { enabled: true, durationMs: 140, easing: "easeInOut" },
  },
};

fs.mkdirSync(outputDirectory, { recursive: true });
for (const [family, familyTokens] of Object.entries(families)) {
  for (const [paletteName, palette] of Object.entries(palettes)) {
    const theme = {
      schemaVersion: 1,
      id: `${family}.${paletteName}`,
      name: `${familyDisplayName(family)} · ${palette.name}`,
      family,
      palette: {
        name: palette.name,
        colors: palette.colors,
      },
      typography: familyTokens.typography,
      cornerRadius: familyTokens.cornerRadius,
      border: {
        color: paletteName === "highContrast" ? "#FFFFFF" : palette.colors.accent,
        ...familyTokens.border,
      },
      shadow: {
        color: palette.shadow,
        ...familyTokens.shadow,
      },
      noise: familyTokens.noise,
      blur: familyTokens.blur,
      collapsedOpacity: familyTokens.collapsedOpacity,
      expandedOpacity: familyTokens.expandedOpacity,
      animation: familyTokens.animation,
    };
    const name = `${family}-${paletteName}.json`;
    fs.writeFileSync(path.join(outputDirectory, name), `${JSON.stringify(theme, null, 2)}\n`, {
      mode: 0o600,
    });
  }
}

console.log(outputDirectory);

function familyDisplayName(family) {
  switch (family) {
    case "nativeGlass":
      return "Native Glass";
    case "retroTerminal":
      return "Retro Terminal";
    case "minimalOLED":
      return "Minimal OLED";
    default:
      throw new Error(`Unknown family: ${family}`);
  }
}
