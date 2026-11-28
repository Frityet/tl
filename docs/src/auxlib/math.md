# Numeric helpers in `auxlib.math`

Use `auxlib.math` to work with bounded values, interpolate ranges, and
apply easing to a progress value.

```teal
local numbers = require("auxlib.math")

local progress = numbers.inv_lerp(0, 100, 25)
print(numbers.lerp(0, 1, progress)) -- 0.25
print(numbers.lerp(10, 20, 1.2)) -- 20
```

| Function | Behavior |
| --- | --- |
| `clamp(v, lo, hi)` | Bound `v` to the interval from `lo` to `hi`. |
| `clamp_int(v, lo, hi)` | Round `v` to an integer, then apply the integer bounds. |
| `lerp(a, b, t)` | Interpolate from `a` to `b` with `t` clamped to `[0, 1]`. |
| `inv_lerp(a, b, v)` | Return the position of `v` in the range as a fraction in `[0, 1]`. Returns zero when the span's magnitude is below `1e-9`. |
| `remap(v, in_lo, in_hi, out_lo, out_hi)` | Calls `lerp(inv_lerp(v, in_lo, in_hi), out_lo, out_hi)` in the current implementation. |
| `round(v, decimals?)` | Round to an integer by default or to the given number of decimal places. Halfway values round toward positive infinity. |
| `sigmoid(x)` | Return the logistic value of `x`. |
| `smooth_damp(current, target, speed, dt)` | Take an exponential step toward `target`. A `dt` of zero or less leaves the current value in place. |
| `ease_out_quad(t)` | Apply quadratic ease-out after clamping `t` to `[0, 1]`. |
| `ease_out_cubic(t)` | Apply cubic ease-out after clamping `t` to `[0, 1]`. |
| `ease_in_out_cubic(t)` | Apply cubic ease-in and ease-out after clamping `t` to `[0, 1]`. |
