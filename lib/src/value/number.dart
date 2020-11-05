// Copyright 2016 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:math';

import 'package:meta/meta.dart';
import 'package:tuple/tuple.dart';

import '../exception.dart';
import '../util/number.dart';
import '../utils.dart';
import '../value.dart';
import '../visitor/interface/value.dart';

/// A nested map containing unit conversion rates.
///
/// `1unit1 * _conversions[unit1][unit2] = 1unit2`.
final _conversions = {
  // Length
  "in": {
    "in": 1,
    "cm": 1 / 2.54,
    "pc": 1 / 6,
    "mm": 1 / 25.4,
    "q": 1 / 101.6,
    "pt": 1 / 72,
    "px": 1 / 96,
  },
  "cm": {
    "in": 2.54,
    "cm": 1,
    "pc": 2.54 / 6,
    "mm": 1 / 10,
    "q": 1 / 40,
    "pt": 2.54 / 72,
    "px": 2.54 / 96,
  },
  "pc": {
    "in": 6,
    "cm": 6 / 2.54,
    "pc": 1,
    "mm": 6 / 25.4,
    "q": 6 / 101.6,
    "pt": 1 / 12,
    "px": 1 / 16,
  },
  "mm": {
    "in": 25.4,
    "cm": 10,
    "pc": 25.4 / 6,
    "mm": 1,
    "q": 1 / 4,
    "pt": 25.4 / 72,
    "px": 25.4 / 96,
  },
  "q": {
    "in": 101.6,
    "cm": 40,
    "pc": 101.6 / 6,
    "mm": 4,
    "q": 1,
    "pt": 101.6 / 72,
    "px": 101.6 / 96,
  },
  "pt": {
    "in": 72,
    "cm": 72 / 2.54,
    "pc": 12,
    "mm": 72 / 25.4,
    "q": 72 / 101.6,
    "pt": 1,
    "px": 3 / 4,
  },
  "px": {
    "in": 96,
    "cm": 96 / 2.54,
    "pc": 16,
    "mm": 96 / 25.4,
    "q": 96 / 101.6,
    "pt": 4 / 3,
    "px": 1,
  },

  // Rotation
  "deg": {
    "deg": 1,
    "grad": 9 / 10,
    "rad": 180 / pi,
    "turn": 360,
  },
  "grad": {
    "deg": 10 / 9,
    "grad": 1,
    "rad": 200 / pi,
    "turn": 400,
  },
  "rad": {
    "deg": pi / 180,
    "grad": pi / 200,
    "rad": 1,
    "turn": 2 * pi,
  },
  "turn": {
    "deg": 1 / 360,
    "grad": 1 / 400,
    "rad": 1 / (2 * pi),
    "turn": 1,
  },

  // Time
  "s": {
    "s": 1,
    "ms": 1 / 1000,
  },
  "ms": {
    "s": 1000,
    "ms": 1,
  },

  // Frequency
  "Hz": {"Hz": 1, "kHz": 1000},
  "kHz": {"Hz": 1 / 1000, "kHz": 1},

  // Pixel density
  "dpi": {
    "dpi": 1,
    "dpcm": 2.54,
    "dppx": 96,
  },
  "dpcm": {
    "dpi": 1 / 2.54,
    "dpcm": 1,
    "dppx": 96 / 2.54,
  },
  "dppx": {
    "dpi": 1 / 96,
    "dpcm": 2.54 / 96,
    "dppx": 1,
  },
};

// TODO(nweiz): If it's faster, add subclasses specifically for unitless numbers
// and numbers with only a single numerator unit. These should be opaque to
// users of SassNumber.

/// A SassScript number.
///
/// Numbers can have units. Although there's no literal syntax for it, numbers
/// support scientific-style numerator and denominator units (for example,
/// `miles/hour`). These are expected to be resolved before being emitted to
/// CSS.
@sealed
class SassNumber extends Value {
  /// The number of distinct digits that are emitted when converting a number to
  /// CSS.
  static const precision = 10;

  /// The value of this number.
  ///
  /// Note that due to details of floating-point arithmetic, this may be a
  /// [double] even if [this] represents an int from Sass's perspective. Use
  /// [isInt] to determine whether this is an integer, [asInt] to get its
  /// integer value, or [assertInt] to do both at once.
  final num value;

  /// This number's numerator units.
  final List<String> numeratorUnits;

  /// This number's denominator units.
  final List<String> denominatorUnits;

  /// The representation of this number as two slash-separated numbers, if it
  /// has one.
  ///
  /// @nodoc
  @internal
  final Tuple2<SassNumber, SassNumber> asSlash;

  /// Whether [this] has any units.
  ///
  /// If a function expects a number to have no units, it should use
  /// [assertNoUnits]. If it expects the number to have a particular unit, it
  /// should use [assertUnit].
  bool get hasUnits => numeratorUnits.isNotEmpty || denominatorUnits.isNotEmpty;

  /// Whether [this] is an integer, according to [fuzzyEquals].
  ///
  /// The [int] value can be accessed using [asInt] or [assertInt]. Note that
  /// this may return `false` for very large doubles even though they may be
  /// mathematically integers, because not all platforms have a valid
  /// representation for integers that large.
  bool get isInt => fuzzyIsInt(value);

  /// If [this] is an integer according to [isInt], returns [value] as an [int].
  ///
  /// Otherwise, returns `null`.
  int get asInt => fuzzyAsInt(value);

  /// Returns a human readable string representation of this number's units.
  ///
  /// @nodoc
  @internal
  String get unitString =>
      hasUnits ? _unitString(numeratorUnits, denominatorUnits) : '';

  /// Creates a number, optionally with a single numerator unit.
  ///
  /// This matches the numbers that can be written as literals.
  /// [SassNumber.withUnits] can be used to construct more complex units.
  SassNumber(num value, [String unit])
      : this.withUnits(value, numeratorUnits: unit == null ? null : [unit]);

  /// Creates a number with full [numeratorUnits] and [denominatorUnits].
  SassNumber.withUnits(this.value,
      {Iterable<String> numeratorUnits, Iterable<String> denominatorUnits})
      : numeratorUnits = numeratorUnits == null
            ? const []
            : List.unmodifiable(numeratorUnits),
        denominatorUnits = denominatorUnits == null
            ? const []
            : List.unmodifiable(denominatorUnits),
        asSlash = null;

  SassNumber._(this.value, this.numeratorUnits, this.denominatorUnits,
      [this.asSlash]);

  /// @nodoc
  @internal
  T accept<T>(ValueVisitor<T> visitor) => visitor.visitNumber(this);

  /// Returns a copy of [this] without [asSlash] set.
  SassNumber withoutSlash() {
    if (asSlash == null) return this;
    return SassNumber._(value, numeratorUnits, denominatorUnits);
  }

  /// Returns a copy of [this] with [this.asSlash] set to a tuple containing
  /// [numerator] and [denominator].
  SassNumber withSlash(SassNumber numerator, SassNumber denominator) =>
      SassNumber._(value, numeratorUnits, denominatorUnits,
          Tuple2(numerator, denominator));

  SassNumber assertNumber([String name]) => this;

  /// Returns [value] as an [int], if it's an integer value according to
  /// [isInt].
  ///
  /// Throws a [SassScriptException] if [value] isn't an integer. If this came
  /// from a function argument, [name] is the argument name (without the `$`).
  /// It's used for error reporting.
  int assertInt([String name]) {
    var integer = fuzzyAsInt(value);
    if (integer != null) return integer;
    throw _exception("$this is not an int.", name);
  }

  /// If [value] is between [min] and [max], returns it.
  ///
  /// If [value] is [fuzzyEquals] to [min] or [max], it's clamped to the
  /// appropriate value. Otherwise, this throws a [SassScriptException]. If this
  /// came from a function argument, [name] is the argument name (without the
  /// `$`). It's used for error reporting.
  num valueInRange(num min, num max, [String name]) {
    var result = fuzzyCheckRange(value, min, max);
    if (result != null) return result;
    throw _exception(
        "Expected $this to be within $min$unitString and $max$unitString.",
        name);
  }

  /// Returns whether [this] has [unit] as its only unit (and as a numerator).
  bool hasUnit(String unit) =>
      numeratorUnits.length == 1 &&
      denominatorUnits.isEmpty &&
      numeratorUnits.first == unit;

  /// Throws a [SassScriptException] unless [this] has [unit] as its only unit
  /// (and as a numerator).
  ///
  /// If this came from a function argument, [name] is the argument name
  /// (without the `$`). It's used for error reporting.
  void assertUnit(String unit, [String name]) {
    if (hasUnit(unit)) return;
    throw _exception('Expected $this to have unit "$unit".', name);
  }

  /// Throws a [SassScriptException] unless [this] has no units.
  ///
  /// If this came from a function argument, [name] is the argument name
  /// (without the `$`). It's used for error reporting.
  void assertNoUnits([String name]) {
    if (!hasUnits) return;
    throw _exception('Expected $this to have no units.', name);
  }

  /// Returns a copy of this number, converted to the units represented by
  /// [newNumerators] and [newDenominators].
  ///
  /// Note that [valueInUnits] is generally more efficient if the value is going
  /// to be accessed directly.
  ///
  /// Throws a [SassScriptException] if this number's units aren't compatible
  /// with [newNumerators] and [newDenominators].
  SassNumber coerce(List<String> newNumerators, List<String> newDenominators) =>
      SassNumber.withUnits(valueInUnits(newNumerators, newDenominators),
          numeratorUnits: newNumerators, denominatorUnits: newDenominators);

  /// Returns [value], converted to the units represented by [newNumerators] and
  /// [newDenominators].
  ///
  /// Throws a [SassScriptException] if this number's units aren't compatible
  /// with [newNumerators] and [newDenominators].
  num valueInUnits(List<String> newNumerators, List<String> newDenominators) {
    if ((newNumerators.isEmpty && newDenominators.isEmpty) ||
        (numeratorUnits.isEmpty && denominatorUnits.isEmpty) ||
        (listEquals(numeratorUnits, newNumerators) &&
            listEquals(denominatorUnits, newDenominators))) {
      return this.value;
    }

    var value = this.value;
    var oldNumerators = numeratorUnits.toList();
    for (var newNumerator in newNumerators) {
      removeFirstWhere<String>(oldNumerators, (oldNumerator) {
        var factor = _conversionFactor(newNumerator, oldNumerator);
        if (factor == null) return false;
        value *= factor;
        return true;
      }, orElse: () {
        throw SassScriptException("Incompatible units "
            "${_unitString(numeratorUnits, denominatorUnits)} and "
            "${_unitString(newNumerators, newDenominators)}.");
      });
    }

    var oldDenominators = denominatorUnits.toList();
    for (var newDenominator in newDenominators) {
      removeFirstWhere<String>(oldDenominators, (oldDenominator) {
        var factor = _conversionFactor(newDenominator, oldDenominator);
        if (factor == null) return false;
        value /= factor;
        return true;
      }, orElse: () {
        throw SassScriptException("Incompatible units "
            "${_unitString(numeratorUnits, denominatorUnits)} and "
            "${_unitString(newNumerators, newDenominators)}.");
      });
    }

    if (oldNumerators.isNotEmpty || oldDenominators.isNotEmpty) {
      throw SassScriptException("Incompatible units "
          "${_unitString(numeratorUnits, denominatorUnits)} and "
          "${_unitString(newNumerators, newDenominators)}.");
    }

    return value;
  }

  /// Returns whether this number can be compared to [other].
  ///
  /// Two numbers can be compared if they have compatible units, or if either
  /// number has no units.
  ///
  /// @nodoc
  @internal
  bool isComparableTo(SassNumber other) {
    if (!hasUnits || !other.hasUnits) return true;
    try {
      greaterThan(other);
      return true;
    } on SassScriptException {
      return false;
    }
  }

  /// @nodoc
  @internal
  SassBoolean greaterThan(Value other) {
    if (other is SassNumber) {
      return SassBoolean(_coerceUnits(other, fuzzyGreaterThan));
    }
    throw SassScriptException('Undefined operation "$this > $other".');
  }

  /// @nodoc
  @internal
  SassBoolean greaterThanOrEquals(Value other) {
    if (other is SassNumber) {
      return SassBoolean(_coerceUnits(other, fuzzyGreaterThanOrEquals));
    }
    throw SassScriptException('Undefined operation "$this >= $other".');
  }

  /// @nodoc
  @internal
  SassBoolean lessThan(Value other) {
    if (other is SassNumber) {
      return SassBoolean(_coerceUnits(other, fuzzyLessThan));
    }
    throw SassScriptException('Undefined operation "$this < $other".');
  }

  /// @nodoc
  @internal
  SassBoolean lessThanOrEquals(Value other) {
    if (other is SassNumber) {
      return SassBoolean(_coerceUnits(other, fuzzyLessThanOrEquals));
    }
    throw SassScriptException('Undefined operation "$this <= $other".');
  }

  /// @nodoc
  @internal
  Value modulo(Value other) {
    if (other is SassNumber) {
      return _coerceNumber(other, (num1, num2) {
        if (num2 > 0) return num1 % num2;
        if (num2 == 0) return double.nan;

        // Dart has different mod-negative semantics than Ruby, and thus than
        // Sass.
        var result = num1 % num2;
        return result == 0 ? 0 : result + num2;
      });
    }
    throw SassScriptException('Undefined operation "$this % $other".');
  }

  /// @nodoc
  @internal
  Value plus(Value other) {
    if (other is SassNumber) {
      return _coerceNumber(other, (num1, num2) => num1 + num2);
    }
    if (other is! SassColor) return super.plus(other);
    throw SassScriptException('Undefined operation "$this + $other".');
  }

  /// @nodoc
  @internal
  Value minus(Value other) {
    if (other is SassNumber) {
      return _coerceNumber(other, (num1, num2) => num1 - num2);
    }
    if (other is! SassColor) return super.minus(other);
    throw SassScriptException('Undefined operation "$this - $other".');
  }

  /// @nodoc
  @internal
  Value times(Value other) {
    if (other is SassNumber) {
      return _multiplyUnits(value * other.value, numeratorUnits,
          denominatorUnits, other.numeratorUnits, other.denominatorUnits);
    }
    throw SassScriptException('Undefined operation "$this * $other".');
  }

  /// @nodoc
  @internal
  Value dividedBy(Value other) {
    if (other is SassNumber) {
      return _multiplyUnits(value / other.value, numeratorUnits,
          denominatorUnits, other.denominatorUnits, other.numeratorUnits);
    }
    return super.dividedBy(other);
  }

  /// @nodoc
  @internal
  Value unaryPlus() => this;

  /// @nodoc
  @internal
  Value unaryMinus() => SassNumber.withUnits(-value,
      numeratorUnits: numeratorUnits, denominatorUnits: denominatorUnits);

  /// Converts [other]'s value to be compatible with this number's, calls
  /// [operation] with the resulting numbers, and wraps the result in a
  /// [SassNumber].
  ///
  /// Throws a [SassScriptException] if the two numbers' units are incompatible.
  SassNumber _coerceNumber(
      SassNumber other, num operation(num num1, num num2)) {
    var result = _coerceUnits(other, operation);
    return SassNumber.withUnits(result,
        numeratorUnits: hasUnits ? numeratorUnits : other.numeratorUnits,
        denominatorUnits: hasUnits ? denominatorUnits : other.denominatorUnits);
  }

  /// Converts [other]'s value to be compatible with this number's, and calls
  /// [operation] with the resulting numbers.
  ///
  /// Throws a [SassScriptException] if the two numbers' units are incompatible.
  T _coerceUnits<T>(SassNumber other, T operation(num num1, num num2)) {
    num num1;
    num num2;
    if (hasUnits) {
      num1 = value;
      num2 = other.valueInUnits(numeratorUnits, denominatorUnits);
    } else {
      num1 = valueInUnits(other.numeratorUnits, other.denominatorUnits);
      num2 = other.value;
    }

    return operation(num1, num2);
  }

  /// Returns a new number that's equivalent to `value numerators1/denominators1
  /// * 1 numerators2/denominators2`.
  SassNumber _multiplyUnits(
      num value,
      List<String> numerators1,
      List<String> denominators1,
      List<String> numerators2,
      List<String> denominators2) {
    // Short-circuit without allocating any new unit lists if possible.
    if (numerators1.isEmpty) {
      if (denominators2.isEmpty &&
          !_areAnyConvertible(denominators1, numerators2)) {
        return SassNumber.withUnits(value,
            numeratorUnits: numerators2, denominatorUnits: denominators1);
      } else if (denominators1.isEmpty) {
        return SassNumber.withUnits(value,
            numeratorUnits: numerators2, denominatorUnits: denominators2);
      }
    } else if (numerators2.isEmpty) {
      if (denominators2.isEmpty) {
        return SassNumber.withUnits(value,
            numeratorUnits: numerators1, denominatorUnits: denominators2);
      } else if (denominators1.isEmpty &&
          !_areAnyConvertible(numerators1, denominators2)) {
        return SassNumber.withUnits(value,
            numeratorUnits: numerators1, denominatorUnits: denominators2);
      }
    }

    var newNumerators = <String>[];
    var mutableDenominators2 = denominators2.toList();
    for (var numerator in numerators1) {
      removeFirstWhere<String>(mutableDenominators2, (denominator) {
        var factor = _conversionFactor(numerator, denominator);
        if (factor == null) return false;
        value /= factor;
        return true;
      }, orElse: () {
        newNumerators.add(numerator);
        return null;
      });
    }

    var mutableDenominators1 = denominators1.toList();
    for (var numerator in numerators2) {
      removeFirstWhere<String>(mutableDenominators1, (denominator) {
        var factor = _conversionFactor(numerator, denominator);
        if (factor == null) return false;
        value /= factor;
        return true;
      }, orElse: () {
        newNumerators.add(numerator);
        return null;
      });
    }

    return SassNumber.withUnits(value,
        numeratorUnits: newNumerators,
        denominatorUnits: mutableDenominators1..addAll(mutableDenominators2));
  }

  /// Returns whether there exists a unit in [units1] that can be converted to a
  /// unit in [units2].
  bool _areAnyConvertible(List<String> units1, List<String> units2) {
    return units1.any((unit1) {
      if (!_isConvertable(unit1)) return units2.contains(unit1);
      var innerMap = _conversions[unit1];
      return units2.any(innerMap.containsKey);
    });
  }

  /// Returns whether [unit] can be converted to or from any other units.
  bool _isConvertable(String unit) => _conversions.containsKey(unit);

  /// Returns the number of [unit1]s per [unit2].
  ///
  /// Equivalently, `1unit1 * _conversionFactor(unit1, unit2) = 1unit2`.
  num _conversionFactor(String unit1, String unit2) {
    if (unit1 == unit2) return 1;
    var innerMap = _conversions[unit1];
    if (innerMap == null) return null;
    return innerMap[unit2];
  }

  /// Returns a human-readable string representation of [numerators] and
  /// [denominators].
  String _unitString(List<String> numerators, List<String> denominators) {
    if (numerators.isEmpty) {
      if (denominators.isEmpty) return "no units";
      if (denominators.length == 1) return denominators.single + "^-1";
      return "(${denominators.join('*')})^-1";
    }

    if (denominators.isEmpty) return numerators.join("*");

    return "${numerators.join("*")}/${denominators.join("*")}";
  }

  bool operator ==(Object other) {
    if (other is SassNumber) {
      // Unitless numbers are convertable to unit numbers, but not equal, so we
      // special-case unitless here.
      if (hasUnits != other.hasUnits) return false;
      if (!hasUnits) return fuzzyEquals(value, other.value);

      try {
        return _coerceUnits(other, fuzzyEquals);
      } on SassScriptException {
        return false;
      }
    } else {
      return false;
    }
  }

  int get hashCode => fuzzyHashCode(value *
      _canonicalMultiplier(numeratorUnits) /
      _canonicalMultiplier(denominatorUnits));

  /// Returns a multiplier that encapsulates unit equivalence in [units].
  ///
  /// That is, if `X units1 == Y units2`, `X * _canonicalMultiplier(units1) == Y
  /// * _canonicalMultiplier(units2)`.
  num _canonicalMultiplier(List<String> units) =>
      units.fold(1, (multiplier, unit) {
        var innerMap = _conversions[unit];
        return innerMap == null
            ? multiplier
            : multiplier / innerMap.values.first;
      });

  /// Throws a [SassScriptException] with the given [message].
  SassScriptException _exception(String message, [String name]) =>
      SassScriptException(name == null ? message : "\$$name: $message");
}
