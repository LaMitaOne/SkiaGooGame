{*******************************************************************************
  SkiaGooGame v 0.3 alpha (Soft Body Physics & Builder Prototype)
********************************************************************************
  A goo like soft body physics prototype built entirely
  with Skia4Delphi. Features a verlet integration mass-spring system where
  users dynamically build structures by dragging and attaching procedural
  "Goo" nodes. Includes procedural level generation, strict attachment
  validation, and a purely visual goal pipeline.

  Author:  Lara Miriam Tamy Reschke
  License: MIT
********************************************************************************}

unit SkiaGooGame;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.Generics.Collections, System.UITypes, System.SyncObjs, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Skia, System.Skia;

const
  GRAVITY = 800;
  SPRING_STIFFNESS = 0.4;
  CONNECTION_RANGE = 130;
  GOAL_RADIUS = 45;

type
  TGooBall = class
  public
    Pos: TPointF;
    OldPos: TPointF;
    Pinned: Boolean;
    IsDragging: Boolean;
    InStructure: Boolean;
    IsFree: Boolean;
    Radius: Single;
    CanAttach: Boolean;
    InGoal: Boolean; // Freezes the ball invisibly inside the goal
    SuckedTimer: Single; // Timer to animate the suction effect visually
    procedure Init(X, Y: Single; APinned, AIsFree: Boolean);
  end;

  TGooLink = record
    Ball1: TGooBall;
    Ball2: TGooBall;
    RestLength: Single;
  end;

  TObstacle = record
    Rect: TRectF;
  end;

  TSkiaGooGame = class(TSkCustomControl)
  private
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection;
    FLevelStarted: Boolean;
    FGameFrozen: Boolean;
    FIsSucking: Boolean;

    FBalls: TObjectList<TGooBall>;
    FLinks: TList<TGooLink>;
    FObstacles: TList<TObstacle>;
    FDraggingBall: TGooBall;

    FGoalPos: TPointF;
    FLevel: Integer;
    FGooAvailable: Integer;
    FGooInGoal: Integer;
    FGooNeeded: Integer;
    FWinTimer: Single;
    FSuckTimer: Single;

    procedure InitLevel(Level: Integer);
    procedure DoPhysicsUpdate(DeltaSec: Double);
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;

    procedure ApplyConstraints;
    procedure CheckGoal;
    procedure ProcessSuction(DeltaSec: Double);
    function AttachFreeBall(Ball: TGooBall): Boolean;
    function CanAttachToStructure(Ball: TGooBall): Boolean;
    function GetConnectedCluster(Target: TGooBall): TList<TGooBall>;

    procedure DrawBackground(const ACanvas: ISkCanvas);
    procedure DrawLinks(const ACanvas: ISkCanvas);
    procedure DrawBalls(const ACanvas: ISkCanvas);
    procedure DrawObstacles(const ACanvas: ISkCanvas);
    procedure DrawGoal(const ACanvas: ISkCanvas);
    procedure DrawUI(const ACanvas: ISkCanvas);
  protected
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

{ TGooBall }

procedure TGooBall.Init(X, Y: Single; APinned, AIsFree: Boolean);
begin
  Pos := PointF(X, Y);
  OldPos := Pos;
  Self.Pinned := APinned;
  Self.IsFree := AIsFree;
  InStructure := not AIsFree;
  IsDragging := False;
  CanAttach := False;
  InGoal := False;
  SuckedTimer := 0;
  Radius := 12;
end;

{ TSkiaGooGame }

constructor TSkiaGooGame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  Align := TAlignLayout.Client;
  HitTest := True;
  CanFocus := True;

  FActive := True;
  FBalls := TObjectList<TGooBall>.Create(True);
  FLinks := TList<TGooLink>.Create;
  FObstacles := TList<TObstacle>.Create;

  FLevel := 1;
  FGooInGoal := 0;
  FGooNeeded := 3; // Only for UI display now
  FGoalPos := PointF(0, 0);
  FLevelStarted := False;
  FWinTimer := 0;
  FGameFrozen := False;
  FIsSucking := False;
  FSuckTimer := 0;

  StartThread;
end;

destructor TSkiaGooGame.Destroy;
begin
  StopThread;
  FreeAndNil(FBalls);
  FreeAndNil(FLinks);
  FreeAndNil(FObstacles);
  FreeAndNil(FLock);
  inherited;
end;

procedure TSkiaGooGame.Resize;
begin
  inherited;
  if (Width > 200) and (Height > 200) and not FLevelStarted then
  begin
    FLevelStarted := True;
    InitLevel(FLevel);
  end;
end;

procedure TSkiaGooGame.InitLevel(Level: Integer);
var
  I: Integer;
  B1, B2, B3: TGooBall;
  Link: TGooLink;
  Obs: TObstacle;
  ObsCount: Integer;
begin
  FLock.Enter;
  try
    FBalls.Clear;
    FLinks.Clear;
    FObstacles.Clear;

    FWinTimer := 0;
    FGooInGoal := 0;
    FGooAvailable := 20;
    FGameFrozen := False;
    FIsSucking := False;
    FSuckTimer := 0;

    // 1. Starting Structure
    B1 := TGooBall.Create;
    B1.Init(Width / 2 - 50, 80, True, False);
    FBalls.Add(B1);
    B2 := TGooBall.Create;
    B2.Init(Width / 2 + 50, 80, True, False);
    FBalls.Add(B2);
    B3 := TGooBall.Create;
    B3.Init(Width / 2, 160, False, False);
    FBalls.Add(B3);

    Link.Ball1 := B1;
    Link.Ball2 := B2;
    Link.RestLength := 100;
    FLinks.Add(Link);
    Link.Ball1 := B1;
    Link.Ball2 := B3;
    Link.RestLength := 90;
    FLinks.Add(Link);
    Link.Ball1 := B2;
    Link.Ball2 := B3;
    Link.RestLength := 90;
    FLinks.Add(Link);

    // 2. Procedural Obstacles
    ObsCount := 1 + Level;
    Randomize;
    for I := 0 to ObsCount - 1 do
    begin
      Obs.Rect := TRectF.Create(200 + System.Random(Trunc(Width) - 400), 200 + System.Random(Trunc(Height) - 350), 0, 0);
      Obs.Rect.Width := 50 + System.Random(100);
      Obs.Rect.Height := 30 + System.Random(80);
      FObstacles.Add(Obs);
    end;

    // 3. Goal Position (Drawn in the background)
    FGoalPos := PointF(Width - 80, Height - 150);
  finally
    FLock.Leave;
  end;
end;

procedure TSkiaGooGame.DoPhysicsUpdate(DeltaSec: Double);
var
  I: Integer;
  Ball: TGooBall;
  VX, VY: Single;
begin
  if not FActive or not FLevelStarted then
    Exit;

  FLock.Enter;
  try
    // If the level was won, freeze physics completely and just count down the timer
    if FGameFrozen then
    begin
      FWinTimer := FWinTimer - DeltaSec;
      if FWinTimer <= 0 then
      begin
        Inc(FLevel);
        InitLevel(FLevel);
      end;
      Exit;
    end;

    // If the vacuums are sucking the structure, animate it
    if FIsSucking then
    begin
      ProcessSuction(DeltaSec);
      Exit;
    end;

    // Verlet Integration
    for I := 0 to FBalls.Count - 1 do
    begin
      Ball := FBalls[I];
      if Ball.Pinned or Ball.IsDragging or Ball.InGoal then
        Continue;

      VX := (Ball.Pos.X - Ball.OldPos.X) * 0.99;
      VY := (Ball.Pos.Y - Ball.OldPos.Y) * 0.99;

      Ball.OldPos := Ball.Pos;
      Ball.Pos.X := Ball.Pos.X + VX;
      Ball.Pos.Y := Ball.Pos.Y + VY + GRAVITY * DeltaSec * DeltaSec;
    end;

    // Apply constraints
    for I := 0 to 4 do
      ApplyConstraints;

    CheckGoal;
  finally
    FLock.Leave;
  end;
end;

procedure TSkiaGooGame.ApplyConstraints;
var
  I, J: Integer;
  Link: TGooLink;
  DX, DY, Dist, Diff, OffsetX, OffsetY: Single;
  Ball: TGooBall;
  Obs: TObstacle;
  ClosestX, ClosestY: Single;
begin
  // Spring Constraints
  for I := 0 to FLinks.Count - 1 do
  begin
    Link := FLinks[I];
    if Link.Ball1.InGoal or Link.Ball2.InGoal then
      Continue;

    DX := Link.Ball2.Pos.X - Link.Ball1.Pos.X;
    DY := Link.Ball2.Pos.Y - Link.Ball1.Pos.Y;
    Dist := Hypot(DX, DY);

    if Dist = 0 then
      Dist := 0.0001;
    Diff := (Dist - Link.RestLength) / Dist;

    OffsetX := DX * 0.5 * Diff * SPRING_STIFFNESS;
    OffsetY := DY * 0.5 * Diff * SPRING_STIFFNESS;

    if not Link.Ball1.Pinned and not Link.Ball1.IsDragging then
    begin
      Link.Ball1.Pos.X := Link.Ball1.Pos.X + OffsetX;
      Link.Ball1.Pos.Y := Link.Ball1.Pos.Y + OffsetY;
    end;

    if not Link.Ball2.Pinned and not Link.Ball2.IsDragging then
    begin
      Link.Ball2.Pos.X := Link.Ball2.Pos.X - OffsetX;
      Link.Ball2.Pos.Y := Link.Ball2.Pos.Y - OffsetY;
    end;
  end;

  // Boundary Constraints
  for I := 0 to FBalls.Count - 1 do
  begin
    Ball := FBalls[I];
    if Ball.IsDragging or Ball.InGoal then
      Continue;

    if Ball.Pos.Y > Height - 40 - Ball.Radius then
    begin
      Ball.Pos.Y := Height - 40 - Ball.Radius;
      if (Ball.Pos.Y - Ball.OldPos.Y) > 0 then
        Ball.OldPos.Y := Ball.Pos.Y + (Ball.Pos.Y - Ball.OldPos.Y) * 0.5;
    end;

    if Ball.Pos.X < Ball.Radius then
      Ball.Pos.X := Ball.Radius;
    if Ball.Pos.X > Width - Ball.Radius then
      Ball.Pos.X := Width - Ball.Radius;

    // Obstacles
    for J := 0 to FObstacles.Count - 1 do
    begin
      Obs := FObstacles[J];
      ClosestX := EnsureRange(Ball.Pos.X, Obs.Rect.Left, Obs.Rect.Right);
      ClosestY := EnsureRange(Ball.Pos.Y, Obs.Rect.Top, Obs.Rect.Bottom);

      DX := Ball.Pos.X - ClosestX;
      DY := Ball.Pos.Y - ClosestY;
      Dist := Hypot(DX, DY);

      if Dist < Ball.Radius then
      begin
        if Dist = 0 then
          Dist := 0.0001;
        Ball.Pos.X := ClosestX + (DX / Dist) * Ball.Radius;
        Ball.Pos.Y := ClosestY + (DY / Dist) * Ball.Radius;
      end;
    end;
  end;
end;

procedure TSkiaGooGame.CheckGoal;
var
  I: Integer;
  Ball: TGooBall;
begin
  if FGameFrozen or FIsSucking then
    Exit;

  // Check all balls and suck them in if they are near the goal
  for I := 0 to FBalls.Count - 1 do
  begin
    Ball := FBalls[I];
    if Ball.Pinned or Ball.InGoal or Ball.IsDragging then
      Continue;

    // If a ball is simply near the goal area (Goal + 10px radius), mark it!
    if Hypot(Ball.Pos.X - FGoalPos.X, Ball.Pos.Y - FGoalPos.Y) < (GOAL_RADIUS + 10) then
    begin
      Ball.InGoal := True;
      Inc(FGooInGoal);

      // Start sucking immediately. NO WIN CHECK HERE.
      FIsSucking := True;
      FSuckTimer := 0;
      Break;
    end;
  end;
end;

function TSkiaGooGame.GetConnectedCluster(Target: TGooBall): TList<TGooBall>;
var
  Visited: TList<TGooBall>;
  Queue: TQueue<TGooBall>;
  Current, Neighbor: TGooBall;
  Link: TGooLink;
  I: Integer;
begin
  Result := TList<TGooBall>.Create;
  if not FBalls.Contains(Target) then
    Exit;

  Visited := TList<TGooBall>.Create;
  Queue := TQueue<TGooBall>.Create;
  try
    Visited.Add(Target);
    Queue.Enqueue(Target);

    while Queue.Count > 0 do
    begin
      Current := Queue.Dequeue;
      Result.Add(Current);

      for I := 0 to FLinks.Count - 1 do
      begin
        Link := FLinks[I];

        // DO NOT ignore links where one is in goal, so the cluster stays connected!
        if Link.Ball1 = Current then
          Neighbor := Link.Ball2
        else if Link.Ball2 = Current then
          Neighbor := Link.Ball1
        else
          Continue;

        if not Visited.Contains(Neighbor) then
        begin
          Visited.Add(Neighbor);
          Queue.Enqueue(Neighbor);
        end;
      end;
    end;
  finally
    Visited.Free;
    Queue.Free;
  end;
end;

procedure TSkiaGooGame.ProcessSuction(DeltaSec: Double);
var
  I: Integer;
  Ball: TGooBall;
  SuckTarget: TGooBall;
  Cluster: TList<TGooBall>;
  FoundOutside: Boolean;
  T: Single;
  TargetX, TargetY: Single;
begin
  FSuckTimer := FSuckTimer + DeltaSec;

  SuckTarget := nil;
  for I := 0 to FBalls.Count - 1 do
  begin
    if FBalls[I].InGoal then
    begin
      SuckTarget := FBalls[I];
      Break;
    end;
  end;

  if SuckTarget = nil then
    Exit;

  // Get the entire cluster of balls connected to the target
  Cluster := GetConnectedCluster(SuckTarget);
  try
    FoundOutside := False;

    for I := 0 to Cluster.Count - 1 do
    begin
      Ball := Cluster[I];
      if Ball.InGoal then
        Continue;

      FoundOutside := True; // We found a ball still hanging outside!

      Ball.SuckedTimer := Ball.SuckedTimer + DeltaSec;
      T := EnsureRange(Ball.SuckedTimer / 0.8, 0.0, 1.0); // Faster animation

      TargetX := FGoalPos.X + (System.Random(20) - 10);
      TargetY := FGoalPos.Y + (System.Random(20) - 10);

      Ball.Pos.X := Ball.Pos.X + (TargetX - Ball.Pos.X) * T;
      Ball.Pos.Y := Ball.Pos.Y + (TargetY - Ball.Pos.Y) * T;

      if Hypot(Ball.Pos.X - FGoalPos.X, Ball.Pos.Y - FGoalPos.Y) < 5 then
      begin
        Ball.InGoal := True;
        Inc(FGooInGoal);
      end;
    end;

    // Once absolutely NO balls are left outside, freeze the game and start the win timer
    if not FoundOutside then
    begin
      FIsSucking := False;
      FGameFrozen := True;
      FWinTimer := 2.0;
    end;
  finally
    Cluster.Free;
  end;
end;

function TSkiaGooGame.CanAttachToStructure(Ball: TGooBall): Boolean;
var
  I, Count: Integer;
  TempDist: Single;
begin
  Result := False;
  Count := 0;

  for I := 0 to FBalls.Count - 1 do
  begin
    if (FBalls[I] <> Ball) and (FBalls[I].InStructure) and not FBalls[I].InGoal then
    begin
      TempDist := Hypot(Ball.Pos.X - FBalls[I].Pos.X, Ball.Pos.Y - FBalls[I].Pos.Y);
      if TempDist <= CONNECTION_RANGE then
      begin
        Inc(Count);
        if Count >= 2 then
        begin
          Result := True;
          Exit;
        end;
      end;
    end;
  end;
end;

function TSkiaGooGame.AttachFreeBall(Ball: TGooBall): Boolean;
var
  I, Count: Integer;
  Links: array of record
    BallRef: TGooBall;
    Dist: Single;
  end;
  Link: TGooLink;
  TempDist: Single;
  TempBall: TGooBall;
  Swapped: Boolean;
begin
  Result := False;
  SetLength(Links, FBalls.Count);
  Count := 0;

  for I := 0 to FBalls.Count - 1 do
  begin
    if (FBalls[I] <> Ball) and (FBalls[I].InStructure) and not FBalls[I].InGoal then
    begin
      TempDist := Hypot(Ball.Pos.X - FBalls[I].Pos.X, Ball.Pos.Y - FBalls[I].Pos.Y);
      if TempDist <= CONNECTION_RANGE then
      begin
        Links[Count].BallRef := FBalls[I];
        Links[Count].Dist := TempDist;
        Inc(Count);
      end;
    end;
  end;

  if Count >= 2 then
  begin
    repeat
      Swapped := False;
      for I := 0 to Count - 2 do
      begin
        if Links[I].Dist > Links[I + 1].Dist then
        begin
          TempBall := Links[I].BallRef;
          TempDist := Links[I].Dist;
          Links[I].BallRef := Links[I + 1].BallRef;
          Links[I].Dist := Links[I + 1].Dist;
          Links[I + 1].BallRef := TempBall;
          Links[I + 1].Dist := TempDist;
          Swapped := True;
        end;
      end;
    until not Swapped;

    if Count > 3 then
      Count := 3;
    Ball.InStructure := True;
    Ball.IsFree := False;

    for I := 0 to Count - 1 do
    begin
      Link.Ball1 := Ball;
      Link.Ball2 := Links[I].BallRef;
      Link.RestLength := Hypot(Ball.Pos.X - Link.Ball2.Pos.X, Ball.Pos.Y - Link.Ball2.Pos.Y);
      FLinks.Add(Link);
    end;

    Result := True;
  end
  else
  begin
    Ball.IsFree := False;
  end;
end;

procedure TSkiaGooGame.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  I: Integer;
  Ball, NewBall: TGooBall;
begin
  if Button = TMouseButton.mbLeft then
  begin
    if FGameFrozen or FIsSucking then
      Exit;

    FLock.Enter;
    try
      for I := 0 to FBalls.Count - 1 do
      begin
        Ball := FBalls[I];
        if not Ball.InGoal and (Hypot(X - Ball.Pos.X, Y - Ball.Pos.Y) < Ball.Radius + 5) then
        begin
          FDraggingBall := Ball;
          Ball.IsDragging := True;
          Break;
        end;
      end;

      if (FDraggingBall = nil) and (FGooAvailable > 0) then
      begin
        NewBall := TGooBall.Create;
        NewBall.Init(X, Y, False, True);
        FBalls.Add(NewBall);
        Dec(FGooAvailable);

        FDraggingBall := NewBall;
        NewBall.IsDragging := True;
      end;
    finally
      FLock.Leave;
    end;
  end;
  inherited;
end;

procedure TSkiaGooGame.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  if Assigned(FDraggingBall) and not FGameFrozen and not FIsSucking then
  begin
    FDraggingBall.Pos := PointF(X, Y);
    FDraggingBall.OldPos := PointF(X, Y);

    if FDraggingBall.IsFree then
      FDraggingBall.CanAttach := CanAttachToStructure(FDraggingBall);
  end;
  inherited;
end;

procedure TSkiaGooGame.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  FLock.Enter;
  try
    if Assigned(FDraggingBall) and not FGameFrozen and not FIsSucking then
    begin
      if FDraggingBall.IsFree then
        AttachFreeBall(FDraggingBall);

      FDraggingBall.IsDragging := False;
      FDraggingBall := nil;
    end;
  finally
    FLock.Leave;
  end;
  inherited;
end;

procedure TSkiaGooGame.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  DrawBackground(ACanvas);

  if not FLevelStarted then
    Exit;

  DrawObstacles(ACanvas);

  // Draw the goal in the background so balls can be placed directly on it
  DrawGoal(ACanvas);

  FLock.Enter;
  try
    DrawLinks(ACanvas);
    DrawBalls(ACanvas);
  finally
    FLock.Leave;
  end;

  DrawUI(ACanvas);
end;

procedure TSkiaGooGame.DrawBackground(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
begin
  ACanvas.Clear($FF223322);

  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.Color := $FF112211;
  ACanvas.DrawRect(TRectF.Create(0, Height - 40, Width, Height), Paint);
end;

procedure TSkiaGooGame.DrawObstacles(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  Obs: TObstacle;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.Color := $FF554433;

  for Obs in FObstacles do
    ACanvas.DrawRoundRect(Obs.Rect, 8, 8, Paint);
end;

procedure TSkiaGooGame.DrawGoal(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  Time: Single;
  Pulse: Single;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;

  Time := TThread.GetTickCount / 400;
  Pulse := (Sin(Time) + 1) / 2;

  // Red Border
  Paint.Color := $FFFF0000;
  Paint.Alpha := 255;
  ACanvas.DrawCircle(FGoalPos, GOAL_RADIUS, Paint);

  // Pulsing Cyan Inner Body
  Paint.Color := $FF00FFFF;
  Paint.Alpha := Round(150 + Pulse * 100);
  ACanvas.DrawCircle(FGoalPos, GOAL_RADIUS - 10, Paint);
end;

procedure TSkiaGooGame.DrawLinks(const ACanvas: ISkCanvas);
var
  I: Integer;
  Link: TGooLink;
  Paint: ISkPaint;
  Dist, T: Single;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Stroke);
  Paint.AntiAlias := True;
  Paint.StrokeCap := TSkStrokeCap.Round;

  for I := 0 to FLinks.Count - 1 do
  begin
    Link := FLinks[I];
    if Link.Ball1.InGoal or Link.Ball2.InGoal then
      Continue;

    Dist := Hypot(Link.Ball2.Pos.X - Link.Ball1.Pos.X, Link.Ball2.Pos.Y - Link.Ball1.Pos.Y);
    if Dist = 0 then
      Dist := 0.0001;

    T := EnsureRange(Link.RestLength / Dist, 0.5, 2.0);
    Paint.StrokeWidth := 6 * T;

    Paint.Color := $FF33AA33;
    ACanvas.DrawLine(Link.Ball1.Pos, Link.Ball2.Pos, Paint);

    Paint.StrokeWidth := 2 * T;
    Paint.Color := $FF88DD88;
    ACanvas.DrawLine(Link.Ball1.Pos, Link.Ball2.Pos, Paint);
  end;
end;

procedure TSkiaGooGame.DrawBalls(const ACanvas: ISkCanvas);
var
  I: Integer;
  Ball: TGooBall;
  Paint: ISkPaint;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;

  for I := 0 to FBalls.Count - 1 do
  begin
    Ball := FBalls[I];
    if Ball.InGoal then
      Continue;

    if Ball.IsDragging and Ball.IsFree then
    begin
      Paint.Style := TSkPaintStyle.Stroke;
      Paint.StrokeWidth := 2;
      if Ball.CanAttach then
        Paint.Color := $FF00FF00
      else
        Paint.Color := $FFFF0000;

      ACanvas.DrawCircle(Ball.Pos, CONNECTION_RANGE, Paint);
      Paint.Style := TSkPaintStyle.Fill;
    end;

    // Drop Shadow
    Paint.Color := $FF000000;
    Paint.Alpha := 80;
    ACanvas.DrawOval(TRectF.Create(Ball.Pos.X - Ball.Radius + 2, Ball.Pos.Y + Ball.Radius - 4, Ball.Pos.X + Ball.Radius + 2, Ball.Pos.Y + Ball.Radius + 2), Paint);
    Paint.Alpha := 255;

    // Ball Body Color
    if Ball.Pinned then
      Paint.Color := $FFAA3333
    else if Ball.IsFree then
      Paint.Color := $FF33AAFF
    else
      Paint.Color := $FF111111;

    ACanvas.DrawCircle(Ball.Pos, Ball.Radius, Paint);

    // Eyes
    Paint.Color := $FFFFFFFF;
    ACanvas.DrawCircle(PointF(Ball.Pos.X - 4, Ball.Pos.Y - 2), 3, Paint);
    ACanvas.DrawCircle(PointF(Ball.Pos.X + 4, Ball.Pos.Y - 2), 3, Paint);

    Paint.Color := $FF000000;
    ACanvas.DrawCircle(PointF(Ball.Pos.X - 4, Ball.Pos.Y - 2), 1, Paint);
    ACanvas.DrawCircle(PointF(Ball.Pos.X + 4, Ball.Pos.Y - 2), 1, Paint);
  end;
end;

procedure TSkiaGooGame.DrawUI(const ACanvas: ISkCanvas);
var
  Font: TSkFont;
  BigFont: TSkFont;
  Paint: ISkPaint;
begin
  Font := TSkFont.Create(nil, 12);
  BigFont := TSkFont.Create(nil, 40);

  Paint := TSkPaint.Create;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.AntiAlias := True;
  Paint.Color := TAlphaColors.White;

  ACanvas.DrawSimpleText(Format('Level: %d', [FLevel]), 10, 30, Font, Paint);
  ACanvas.DrawSimpleText(Format('Available Goo: %d', [FGooAvailable]), 10, 55, Font, Paint);
  ACanvas.DrawSimpleText(Format('Goal: %d / %d', [FGooInGoal, FGooNeeded]), 10, 80, Font, Paint);

  if FGameFrozen then
  begin
    Paint.Color := $FF00FF00;
    ACanvas.DrawSimpleText('LEVEL COMPLETE!', Width / 2 - 150, Height / 2, BigFont, Paint);
  end
  else
  begin
    Paint.Color := $FFAAAAAA;
    ACanvas.DrawSimpleText('Drop balls near the structure to attach them. Reach the goal on the right!', 10, Height - 10, Font, Paint);
  end;
end;

procedure TSkiaGooGame.SafeInvalidate;
begin
  if csDestroying in ComponentState then
    Exit;
  TThread.Queue(nil,
    procedure
    begin
      if not (csDestroying in ComponentState) and Assigned(Self) then
      begin
        Redraw;
        Repaint;
      end;
    end);
end;

procedure TSkiaGooGame.StartThread;
begin
  if Assigned(FThread) then
    Exit;
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime, DeltaMS: Cardinal;
    begin
      LastTime := TThread.GetTickCount;
      while not TThread.CheckTerminated do
      begin
        NowTime := TThread.GetTickCount;
        DeltaMS := NowTime - LastTime;
        if DeltaMS = 0 then
          DeltaMS := 1;
        LastTime := NowTime;
        if FActive then
        begin
          DoPhysicsUpdate(DeltaMS / 1000);
          SafeInvalidate;
        end;
        Sleep(16);
      end;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TSkiaGooGame.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50);
  end;
end;

end.

