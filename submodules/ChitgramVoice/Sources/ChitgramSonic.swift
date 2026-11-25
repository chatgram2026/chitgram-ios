/*
 * Copyright (C) 2017 The Android Open Source Project
 * Copyright (C) 2010 Bill Cox, Sonic Library
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

/// Sonic, the time and pitch stream processor (https://github.com/waywardgeek/sonic), as androidx.media3 has it and
/// Chitgram Android copies it unchanged (org/fenixuz/voice/Sonic.java). Ported line by line for one channel, which is
/// all the voice changer gives it; Java's int and long arithmetic is done in Int, and its (short) casts truncate.
final class ChitgramSonic {
    private static let minimumPitch = 65
    private static let maximumPitch = 400
    private static let amdfFrequency = 4000
    private static let minimumSpeedupRate: Float = 1.00001
    private static let minimumSlowdownRate: Float = 0.99999

    private let inputSampleRateHz: Int
    private let speed: Float
    private let pitch: Float
    private let rate: Float
    private let minPeriod: Int
    private let maxPeriod: Int
    private let maxRequiredFrameCount: Int
    private var downSampleBuffer: [Int16]

    private var inputBuffer: [Int16]
    private var inputFrameCount = 0
    private var outputBuffer: [Int16]
    private var outputFrameCount = 0
    private var pitchBuffer: [Int16]
    private var pitchFrameCount = 0
    private var oldRatePosition = 0
    private var newRatePosition = 0
    private var remainingInputToCopyFrameCount = 0
    private var prevPeriod = 0
    private var prevMinDiff = 0
    private var minDiff = 0
    private var maxDiff = 0
    private var accumulatedSpeedAdjustmentError: Double = 0.0

    init(inputSampleRateHz: Int, speed: Float, pitch: Float, outputSampleRateHz: Int) {
        self.inputSampleRateHz = inputSampleRateHz
        self.speed = speed
        self.pitch = pitch
        self.rate = Float(inputSampleRateHz) / Float(outputSampleRateHz)
        self.minPeriod = inputSampleRateHz / ChitgramSonic.maximumPitch
        self.maxPeriod = inputSampleRateHz / ChitgramSonic.minimumPitch
        self.maxRequiredFrameCount = 2 * (inputSampleRateHz / ChitgramSonic.minimumPitch)
        self.downSampleBuffer = [Int16](repeating: 0, count: self.maxRequiredFrameCount)
        self.inputBuffer = [Int16](repeating: 0, count: self.maxRequiredFrameCount)
        self.outputBuffer = [Int16](repeating: 0, count: self.maxRequiredFrameCount)
        self.pitchBuffer = [Int16](repeating: 0, count: self.maxRequiredFrameCount)
    }

    /// Queues the samples and processes what can be processed.
    func queueInput(_ samples: [Int16]) {
        let framesToWrite = samples.count
        ChitgramSonic.ensureSpace(&self.inputBuffer, self.inputFrameCount, framesToWrite)
        for i in 0 ..< framesToWrite {
            self.inputBuffer[self.inputFrameCount + i] = samples[i]
        }
        self.inputFrameCount += framesToWrite
        self.processStreamInput()
    }

    /// Everything processed so far.
    func takeOutput() -> [Int16] {
        let count = self.outputFrameCount
        if count <= 0 {
            return []
        }
        let result = Array(self.outputBuffer[0 ..< count])
        self.outputFrameCount = 0
        return result
    }

    /// Forces out whatever was queued; no delay is added.
    func queueEndOfStream() {
        let remainingFrameCount = self.inputFrameCount
        let s = Double(self.speed / self.pitch)
        let r = Double(self.rate * self.pitch)
        let adjustedRemainingFrames = remainingFrameCount - self.remainingInputToCopyFrameCount
        let expected = (Double(adjustedRemainingFrames) / s + Double(self.remainingInputToCopyFrameCount) + self.accumulatedSpeedAdjustmentError + Double(self.pitchFrameCount)) / r + 0.5
        let expectedOutputFrames = self.outputFrameCount + Int(expected)
        self.accumulatedSpeedAdjustmentError = 0

        // Enough silence to flush both the input and the pitch buffers.
        let silence = 2 * self.maxRequiredFrameCount
        ChitgramSonic.ensureSpace(&self.inputBuffer, self.inputFrameCount, remainingFrameCount + silence)
        for i in 0 ..< silence {
            self.inputBuffer[remainingFrameCount + i] = 0
        }
        self.inputFrameCount += silence
        self.processStreamInput()
        // Throw away the extra frames the silence made.
        if self.outputFrameCount > expectedOutputFrames {
            self.outputFrameCount = max(expectedOutputFrames, 0)
        }
        self.inputFrameCount = 0
        self.remainingInputToCopyFrameCount = 0
        self.pitchFrameCount = 0
    }

    private static func ensureSpace(_ buffer: inout [Int16], _ frameCount: Int, _ additionalFrameCount: Int) {
        let capacity = buffer.count
        if frameCount + additionalFrameCount <= capacity {
            return
        }
        let newCapacity = 3 * capacity / 2 + additionalFrameCount
        buffer.append(contentsOf: [Int16](repeating: 0, count: newCapacity - capacity))
    }

    private func removeProcessedInputFrames(_ positionFrames: Int) {
        let remainingFrames = max(0, self.inputFrameCount - positionFrames)
        if positionFrames > 0 {
            for i in 0 ..< remainingFrames {
                self.inputBuffer[i] = self.inputBuffer[positionFrames + i]
            }
        }
        self.inputFrameCount = remainingFrames
    }

    private func copyToOutput(fromInput positionFrames: Int, _ frameCount: Int) {
        if frameCount <= 0 {
            return
        }
        ChitgramSonic.ensureSpace(&self.outputBuffer, self.outputFrameCount, frameCount)
        for i in 0 ..< frameCount {
            self.outputBuffer[self.outputFrameCount + i] = self.inputBuffer[positionFrames + i]
        }
        self.outputFrameCount += frameCount
    }

    private func copyInputToOutput(_ positionFrames: Int) -> Int {
        let frameCount = min(self.maxRequiredFrameCount, self.remainingInputToCopyFrameCount)
        self.copyToOutput(fromInput: positionFrames, frameCount)
        self.remainingInputToCopyFrameCount -= frameCount
        return frameCount
    }

    private func downSampleInput(_ position: Int, _ skip: Int) {
        // Averages `skip` samples together into the down-sample buffer.
        let frameCount = self.maxRequiredFrameCount / skip
        for i in 0 ..< frameCount {
            var value = 0
            for j in 0 ..< skip {
                value += Int(self.inputBuffer[position + i * skip + j])
            }
            value /= skip
            self.downSampleBuffer[i] = Int16(truncatingIfNeeded: value)
        }
    }

    private func findPitchPeriodInRange(_ samples: [Int16], _ position: Int, _ minPeriod: Int, _ maxPeriod: Int) -> Int {
        var bestPeriod = 0
        var worstPeriod = 255
        var minDiff = 1
        var maxDiff = 0
        if minPeriod <= maxPeriod {
            for period in minPeriod ... maxPeriod {
                var diff = 0
                for i in 0 ..< period {
                    let sVal = Int(samples[position + i])
                    let pVal = Int(samples[position + period + i])
                    diff += abs(sVal - pVal)
                }
                if diff * bestPeriod < minDiff * period {
                    minDiff = diff
                    bestPeriod = period
                }
                if diff * worstPeriod > maxDiff * period {
                    maxDiff = diff
                    worstPeriod = period
                }
            }
        }
        self.minDiff = bestPeriod != 0 ? minDiff / bestPeriod : 0
        self.maxDiff = worstPeriod != 0 ? maxDiff / worstPeriod : 0
        return bestPeriod
    }

    /// Whether the previous pitch period is the better estimate, as at the abrupt end of a voiced word.
    private func previousPeriodBetter(_ minDiff: Int, _ maxDiff: Int) -> Bool {
        if minDiff == 0 || self.prevPeriod == 0 {
            return false
        }
        if maxDiff > minDiff * 3 {
            return false
        }
        if minDiff * 2 <= self.prevMinDiff * 3 {
            return false
        }
        return true
    }

    private func findPitchPeriod(_ position: Int) -> Int {
        // AMDF on the input down-sampled to about 4 kHz, then again in a narrow range at the full rate.
        var period: Int
        let skip = self.inputSampleRateHz > ChitgramSonic.amdfFrequency ? self.inputSampleRateHz / ChitgramSonic.amdfFrequency : 1
        if skip == 1 {
            period = self.findPitchPeriodInRange(self.inputBuffer, position, self.minPeriod, self.maxPeriod)
        } else {
            self.downSampleInput(position, skip)
            period = self.findPitchPeriodInRange(self.downSampleBuffer, 0, self.minPeriod / skip, self.maxPeriod / skip)
            period *= skip
            var minP = period - skip * 4
            var maxP = period + skip * 4
            if minP < self.minPeriod {
                minP = self.minPeriod
            }
            if maxP > self.maxPeriod {
                maxP = self.maxPeriod
            }
            period = self.findPitchPeriodInRange(self.inputBuffer, position, minP, maxP)
        }
        let retPeriod = self.previousPeriodBetter(self.minDiff, self.maxDiff) ? self.prevPeriod : period
        self.prevMinDiff = self.minDiff
        self.prevPeriod = period
        return retPeriod
    }

    private func moveNewSamplesToPitchBuffer(_ originalOutputFrameCount: Int) {
        let frameCount = self.outputFrameCount - originalOutputFrameCount
        if frameCount <= 0 {
            return
        }
        ChitgramSonic.ensureSpace(&self.pitchBuffer, self.pitchFrameCount, frameCount)
        for i in 0 ..< frameCount {
            self.pitchBuffer[self.pitchFrameCount + i] = self.outputBuffer[originalOutputFrameCount + i]
        }
        self.outputFrameCount = originalOutputFrameCount
        self.pitchFrameCount += frameCount
    }

    private func removePitchFrames(_ frameCount: Int) {
        if frameCount <= 0 {
            return
        }
        let remaining = self.pitchFrameCount - frameCount
        if remaining > 0 {
            for i in 0 ..< remaining {
                self.pitchBuffer[i] = self.pitchBuffer[frameCount + i]
            }
        }
        self.pitchFrameCount -= frameCount
    }

    private func interpolate(_ inPos: Int, _ oldSampleRate: Int, _ newSampleRate: Int) -> Int16 {
        let left = Int(self.pitchBuffer[inPos])
        let right = Int(self.pitchBuffer[inPos + 1])
        let position = self.newRatePosition * oldSampleRate
        let leftPosition = self.oldRatePosition * newSampleRate
        let rightPosition = (self.oldRatePosition + 1) * newSampleRate
        let ratio = rightPosition - position
        let width = rightPosition - leftPosition
        if width == 0 {
            return Int16(truncatingIfNeeded: left)
        }
        return Int16(truncatingIfNeeded: (ratio * left + (width - ratio) * right) / width)
    }

    private func adjustRate(_ rate: Float, _ originalOutputFrameCount: Int) {
        if self.outputFrameCount == originalOutputFrameCount {
            return
        }
        var newSampleRate = Int(Float(self.inputSampleRateHz) / rate)
        var oldSampleRate = self.inputSampleRateHz
        while newSampleRate != 0 && oldSampleRate != 0 && newSampleRate % 2 == 0 && oldSampleRate % 2 == 0 {
            newSampleRate /= 2
            oldSampleRate /= 2
        }
        self.moveNewSamplesToPitchBuffer(originalOutputFrameCount)
        // Leaves at least one pitch sample in the buffer.
        var position = 0
        while position < self.pitchFrameCount - 1 {
            while (self.oldRatePosition + 1) * newSampleRate > self.newRatePosition * oldSampleRate {
                ChitgramSonic.ensureSpace(&self.outputBuffer, self.outputFrameCount, 1)
                self.outputBuffer[self.outputFrameCount] = self.interpolate(position, oldSampleRate, newSampleRate)
                self.newRatePosition += 1
                self.outputFrameCount += 1
            }
            self.oldRatePosition += 1
            if self.oldRatePosition == oldSampleRate {
                self.oldRatePosition = 0
                self.newRatePosition = 0
            }
            position += 1
        }
        self.removePitchFrames(self.pitchFrameCount - 1)
    }

    private func overlapAdd(_ frameCount: Int, outPosition: Int, rampDownPosition: Int, rampUpPosition: Int) {
        if frameCount <= 0 {
            return
        }
        for t in 0 ..< frameCount {
            let down = Int(self.inputBuffer[rampDownPosition + t])
            let up = Int(self.inputBuffer[rampUpPosition + t])
            self.outputBuffer[outPosition + t] = Int16(truncatingIfNeeded: (down * (frameCount - t) + up * t) / frameCount)
        }
    }

    private func skipPitchPeriod(_ position: Int, _ speed: Double, _ period: Int) -> Int {
        // Skips a pitch period and copies period / speed samples to the output.
        let newFrameCount: Int
        if speed >= 2.0 {
            let expectedFrameCount = Double(period) / (speed - 1.0) + self.accumulatedSpeedAdjustmentError
            newFrameCount = Int((expectedFrameCount + 0.5).rounded(.down))
            self.accumulatedSpeedAdjustmentError = expectedFrameCount - Double(newFrameCount)
        } else {
            newFrameCount = period
            let expectedInputToCopy = Double(period) * (2.0 - speed) / (speed - 1.0) + self.accumulatedSpeedAdjustmentError
            self.remainingInputToCopyFrameCount = Int((expectedInputToCopy + 0.5).rounded(.down))
            self.accumulatedSpeedAdjustmentError = expectedInputToCopy - Double(self.remainingInputToCopyFrameCount)
        }
        ChitgramSonic.ensureSpace(&self.outputBuffer, self.outputFrameCount, newFrameCount)
        self.overlapAdd(newFrameCount, outPosition: self.outputFrameCount, rampDownPosition: position, rampUpPosition: position + period)
        self.outputFrameCount += newFrameCount
        return newFrameCount
    }

    private func insertPitchPeriod(_ position: Int, _ speed: Double, _ period: Int) -> Int {
        // Inserts a pitch period and works out how much input to copy as it is.
        let newFrameCount: Int
        if speed < 0.5 {
            let expectedFrameCount = Double(period) * speed / (1.0 - speed) + self.accumulatedSpeedAdjustmentError
            newFrameCount = Int((expectedFrameCount + 0.5).rounded(.down))
            self.accumulatedSpeedAdjustmentError = expectedFrameCount - Double(newFrameCount)
        } else {
            newFrameCount = period
            let expectedInputToCopy = Double(period) * (2.0 * speed - 1.0) / (1.0 - speed) + self.accumulatedSpeedAdjustmentError
            self.remainingInputToCopyFrameCount = Int((expectedInputToCopy + 0.5).rounded(.down))
            self.accumulatedSpeedAdjustmentError = expectedInputToCopy - Double(self.remainingInputToCopyFrameCount)
        }
        ChitgramSonic.ensureSpace(&self.outputBuffer, self.outputFrameCount, period + newFrameCount)
        for i in 0 ..< period {
            self.outputBuffer[self.outputFrameCount + i] = self.inputBuffer[position + i]
        }
        self.overlapAdd(newFrameCount, outPosition: self.outputFrameCount + period, rampDownPosition: position + period, rampUpPosition: position)
        self.outputFrameCount += period + newFrameCount
        return newFrameCount
    }

    private func changeSpeed(_ speed: Double) {
        if self.inputFrameCount < self.maxRequiredFrameCount {
            return
        }
        let frameCount = self.inputFrameCount
        var positionFrames = 0
        repeat {
            if self.remainingInputToCopyFrameCount > 0 {
                positionFrames += self.copyInputToOutput(positionFrames)
            } else {
                let period = self.findPitchPeriod(positionFrames)
                if speed > 1.0 {
                    positionFrames += period + self.skipPitchPeriod(positionFrames, speed, period)
                } else {
                    positionFrames += self.insertPitchPeriod(positionFrames, speed, period)
                }
            }
        } while positionFrames + self.maxRequiredFrameCount <= frameCount
        self.removeProcessedInputFrames(positionFrames)
    }

    private func processStreamInput() {
        // Resamples as many pitch periods as the input holds.
        let originalOutputFrameCount = self.outputFrameCount
        let s = Double(self.speed / self.pitch)
        let r = self.rate * self.pitch
        if s > Double(ChitgramSonic.minimumSpeedupRate) || s < Double(ChitgramSonic.minimumSlowdownRate) {
            self.changeSpeed(s)
        } else {
            self.copyToOutput(fromInput: 0, self.inputFrameCount)
            self.inputFrameCount = 0
        }
        if r != 1.0 {
            self.adjustRate(r, originalOutputFrameCount)
        }
    }
}
