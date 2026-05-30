# Battle Stage Background Design Guide

To support multiple thematic backgrounds in the Battle Arena, all stage assets must follow a strict dimensional grid to ensure that 2D game characters stand exactly on the designated player and opponent battle platforms (podiums).

## Core Layout Dimensions

All background images must be designed in a standard **16:9 aspect ratio** (recommended resolution: **1920x1080 pixels**).

When the image is loaded into the Flame engine, it is contained to fit the screen. The coordinates for character positioning are relative to the contained stage rectangle:

| Battle Platform | Horizontal Center (% of Width) | Vertical Base / Anchor (% of Height) | Perspective |
|---|---|---|---|
| **Player Podium** | **24.5%** | **73.0%** | Back-facing perspective (facing away from camera) |
| **Opponent Podium** | **77.5%** | **67.0%** | Front-facing perspective (facing toward camera) |

## visual Alignment Specifications

1. **Podium Anchor Point:** The `anchor: Anchor.bottomCenter` is used to place character sprites. This means the visual center of the top plane of each podium must align exactly at the horizontal and vertical percentages listed above.
2. **Perspective Consistency:**
   - The Player Podium is lower and slightly larger (closer to the camera).
   - The Opponent Podium is higher and slightly smaller (further from the camera), creating depth.
3. **No Intrusive Elements:** Avoid placing equalizers, bright lights, or UI boundaries directly behind the platform coordinates to prevent overlapping with character sprites.
