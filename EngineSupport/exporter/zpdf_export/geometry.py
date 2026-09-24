"""Geometry primitives. Normalized space: displayed CropBox, points, top-left
origin, page /Rotate and /UserUnit resolved."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BBox:
    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def width(self) -> float:
        return self.x1 - self.x0

    @property
    def height(self) -> float:
        return self.y1 - self.y0

    @property
    def cx(self) -> float:
        return (self.x0 + self.x1) / 2

    @property
    def cy(self) -> float:
        return (self.y0 + self.y1) / 2

    def contains_point(self, x: float, y: float) -> bool:
        return self.x0 <= x <= self.x1 and self.y0 <= y <= self.y1

    def intersects(self, other: "BBox") -> bool:
        return not (other.x0 >= self.x1 or other.x1 <= self.x0
                    or other.y0 >= self.y1 or other.y1 <= self.y0)

    def union(self, other: "BBox") -> "BBox":
        return BBox(min(self.x0, other.x0), min(self.y0, other.y0),
                    max(self.x1, other.x1), max(self.y1, other.y1))

    def rounded(self, nd: int = 2) -> list[float]:
        return [round(self.x0, nd), round(self.y0, nd), round(self.x1, nd), round(self.y1, nd)]

    @staticmethod
    def from_points(points) -> "BBox":
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        return BBox(min(xs), min(ys), max(xs), max(ys))
