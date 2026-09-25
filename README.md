# SkiaGooGame    
     
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SkiaGooGame)    
     
<img width="638" height="465" alt="Unbenannt" src="https://github.com/user-attachments/assets/877312ab-f5f8-42ca-b5c4-aa6b5e43b50f" />
    
A world of goo like soft body physics prototype built entirely with Skia4Delphi. Features a verlet integration mass-spring system where users dynamically build structures by dragging and attaching procedural "Goo" nodes. Includes procedural level generation, strict attachment validation, and a purely visual goal pipeline.    
     
Controls:    
    
    Left Click & Drag: Pick up existing Goo balls or spawn new ones from your available pool.
    Release: Drop the ball. If placed near the structure (inside the green indicator), it will automatically attach via dynamic springs to the nearest nodes.
    Goal: Build your structure towards the goal area. Once any part of your structure touches the goal, the entire connected mass is dynamically sucked in to complete the level.
    
Technical Details:    
     
    Physics: Implements Verlet integration for performant mass-spring calculations. Constraint solving is iterated multiple times per frame for structural stability.
    Threading: All physics updates and level state logic are handled on a background thread with a critical section to ensure thread-safe UI updates.
    Graphics: Rendered using Skia4Delphi, utilizing paths, strokes, and pulsing alphas for the visual pipeline.
    
Zipped exe and sample project included   
