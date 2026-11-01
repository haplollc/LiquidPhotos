//
//  LiquidEngine.swift
//  LiquidPhotos
//
//  The stage's state machine: which photo is showing, the transition in
//  flight, playback, and the work done ahead of time (textures, alignments,
//  flows) so a transition never waits when it can avoid it.
//

import Metal
import UIKit
import simd

/// The recording clock. Everything on the stage runs `pace` times slower
/// than real time, so a busy machine can record smooth frames that are sped
/// back up afterwards.
@_spi(Recording)
@MainActor
public enum LiquidTime {
    public static var pace: Double = 1
}

/// What the renderer draws this frame. Photo A is the pair's world; B, when
/// present, is placed in it by `toB`.
struct LiquidDrawState {
    var frame: LiquidMorphFrame
    var textureA: MTLTexture
    var heightA: Double
    var textureB: MTLTexture?
    var heightB: Double
    var toB: simd_double3x3
    var flow: (ab: MTLTexture, ba: MTLTexture, origin: SIMD2<Float>, size: SIMD2<Float>)?
    var opacity: Double
    /// Frames a second this needs: full rate while morphing, a trickle while
    /// only waiting, none when settled.
    var frameRate: Int
}

@MainActor
final class LiquidEngine {
    var style = LiquidPhotosStyle()
    var reduceMotion = UIAccessibility.isReduceMotionEnabled

    /// The selection changed by itself (playback moved on).
    var onSelect: ((Int) -> Void)?
    /// Playback reached the last photo and does not loop.
    var onPlaybackEnd: (() -> Void)?
    /// A new photo was asked for (true), or one has landed (false), with
    /// the index of the photo now on screen.
    var onMotion: ((Bool, Int?) -> Void)?
    /// Called whenever something new is ready to draw.
    var onNeedsDisplay: (() -> Void)?

    let device: MTLDevice
    private let maxPixelSize: Int

    private var photos: [(id: ObjectIdentifier, image: UIImage)] = []
    private var infos: [ObjectIdentifier: LiquidPhotoInfo] = [:]
    private var textures: [ObjectIdentifier: MTLTexture] = [:]
    private var textureUse: [ObjectIdentifier: Int] = [:]
    private var useCounter = 0
    private var loading: Set<ObjectIdentifier> = []
    private var morphs: [PairKey: PreparedMorph] = [:]
    private var morphing: Set<PairKey> = []

    private struct PairKey: Hashable {
        let low: ObjectIdentifier, high: ObjectIdentifier
        init(_ a: ObjectIdentifier, _ b: ObjectIdentifier) {
            low = min(a, b)
            high = max(a, b)
        }
    }

    private struct PreparedMorph {
        let morph: LiquidMorph
        let flow: LiquidMorphFlow
        let ab: MTLTexture
        let ba: MTLTexture
    }

    private struct Transition {
        let from: ObjectIdentifier
        let to: ObjectIdentifier
        let key: PairKey
        var progress: Double = 0
        var speed: Double = 1
    }

    private var shown: ObjectIdentifier?
    private var requested: ObjectIdentifier?
    private var transition: Transition?
    private var appear: Double = 1
    private var restTime: Double = 0
    private var playKick = false
    private var isMoving = false

    var isPlaying = false {
        didSet {
            if isPlaying, !oldValue { playKick = true }
            onNeedsDisplay?()
        }
    }

    init(device: MTLDevice, maxPixelSize: Int = 1800) {
        self.device = device
        self.maxPixelSize = maxPixelSize
    }

    /// Reports motion from the moment a new photo is asked for until it lands.
    private func reportMotion(_ moving: Bool) {
        guard moving != isMoving else { return }
        isMoving = moving
        onMotion?(moving, shown.flatMap { id in photos.firstIndex { $0.id == id } })
    }

    // MARK: Inputs

    func setPhotos(_ images: [UIImage], selection: Int) {
        let next = images.map { (id: ObjectIdentifier($0), image: $0) }
        if next.map(\.id) != photos.map(\.id) {
            let alive = Set(next.map(\.id))
            infos = infos.filter { alive.contains($0.key) }
            textures = textures.filter { alive.contains($0.key) }
            morphs = morphs.filter { alive.contains($0.key.low) && alive.contains($0.key.high) }
            if let t = transition, !alive.contains(t.from) || !alive.contains(t.to) { transition = nil }
            if let s = shown, !alive.contains(s) { shown = nil }
        }
        photos = next
        select(selection)
    }

    func select(_ index: Int) {
        guard photos.indices.contains(index) else {
            requested = nil
            return
        }
        let id = photos[index].id
        guard id != requested else { return }
        requested = id
        if id != shown { reportMotion(true) }
        // A new target mid-transition: hurry the current one along.
        if transition != nil { transition?.speed = 2.6 }
        onNeedsDisplay?()
    }

    // MARK: Frame

    func advance(by realSeconds: Double, maxHeight: Double) -> LiquidDrawState? {
        let dt = min(realSeconds, 0.1) / LiquidTime.pace
        guard !photos.isEmpty else { return nil }

        if shown == nil, let target = requested ?? photos.first?.id, ensureReady(target) {
            shown = target
            appear = 0
            restTime = 0
            if target == requested { reportMotion(false) }
            prefetchNeighbours(of: target)
        }
        guard let shown, let infoShown = infos[shown], let textureShown = textures[shown] else { return nil }
        appear = min(1, appear + dt / 0.35)

        if var t = transition {
            t.progress += dt * t.speed / max(style.transitionDuration, 0.05)
            if t.progress >= 1 {
                transition = nil
                self.shown = t.to
                restTime = 0
                if requested == t.to || requested == nil { reportMotion(false) }
                prefetchNeighbours(of: t.to)
                return advance(by: 0, maxHeight: maxHeight)
            }
            transition = t
        } else {
            restTime += dt
            advancePlayback()
            if let target = requested, target != shown, startTransition(from: shown, to: target) {
                return advance(by: 0, maxHeight: maxHeight)
            }
        }

        if let t = transition, let prepared = morphs[t.key],
           let low = textures[t.key.low], let high = textures[t.key.high] {
            touch(t.from)
            touch(t.to)
            // The pair is stored low → high; going the other way plays it backwards.
            let forward = t.from == t.key.low
            let raw = forward ? t.progress : 1 - t.progress
            var frame = prepared.morph.frame(at: raw, maxHeight: maxHeight)
            if reduceMotion {
                // A plain cross-fade in place.
                let held = LiquidMorph.resting(height: forward ? prepared.morph.heightA : prepared.morph.heightB, maxHeight: maxHeight)
                frame.view = held.view
                frame.motion = 0
            }
            return LiquidDrawState(
                frame: frame,
                textureA: low, heightA: prepared.morph.heightA,
                textureB: high, heightB: prepared.morph.heightB,
                toB: prepared.morph.toB,
                flow: style.morph > 0 && !reduceMotion ? (prepared.ab, prepared.ba, prepared.flow.origin, prepared.flow.size) : nil,
                opacity: appear,
                frameRate: 120
            )
        }

        touch(shown)
        let pending = requested != nil && requested != shown
        return LiquidDrawState(
            frame: LiquidMorph.resting(height: infoShown.height, maxHeight: maxHeight),
            textureA: textureShown, heightA: infoShown.height,
            textureB: nil, heightB: 1, toB: matrix_identity_double3x3,
            flow: nil,
            opacity: appear,
            frameRate: appear < 1 ? 60 : (isPlaying || pending || playKick ? 10 : 0)
        )
    }

    private func advancePlayback() {
        guard isPlaying, photos.count > 1, let shown, requested == shown,
              let index = photos.firstIndex(where: { $0.id == shown }) else { return }
        guard restTime >= (playKick ? 0.15 : style.holdDuration) else { return }
        if index == photos.count - 1, !style.loops {
            isPlaying = false
            onPlaybackEnd?()
            return
        }
        playKick = false
        let next = (index + 1) % photos.count
        requested = photos[next].id
        reportMotion(true)
        onSelect?(next)
    }

    /// Starts the transition once both photos and their morph are ready.
    private func startTransition(from a: ObjectIdentifier, to b: ObjectIdentifier) -> Bool {
        guard ensureReady(a), ensureReady(b) else { return false }
        let key = PairKey(a, b)
        guard morphs[key] != nil else {
            ensureMorph(key)
            return false
        }
        transition = Transition(from: a, to: b, key: key)
        reportMotion(true)
        return true
    }

    // MARK: Preparation

    /// True when the photo's info and texture are ready; otherwise starts
    /// preparing it.
    @discardableResult
    private func ensureReady(_ id: ObjectIdentifier, urgent: Bool = true) -> Bool {
        if infos[id] != nil, textures[id] != nil { return true }
        guard !loading.contains(id), let image = photos.first(where: { $0.id == id })?.image else { return false }
        loading.insert(id)
        let needsInfo = infos[id] == nil
        let box = UncheckedSendable(value: (image, device))
        let maxPixelSize = maxPixelSize
        Task.detached(priority: urgent ? .userInitiated : .utility) {
            let (image, device) = box.value
            guard let upright = LiquidPreparation.uprightImage(image, maxPixelSize: maxPixelSize) else { return }
            let info = needsInfo ? LiquidPreparation.info(for: upright) : nil
            let texture = try? LiquidPreparation.texture(from: upright, device: device)
            let result = UncheckedSendable(value: (info, texture))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(id)
                guard self.photos.contains(where: { $0.id == id }) else { return }
                if let info = result.value.0 { self.infos[id] = info }
                if let texture = result.value.1 {
                    self.textures[id] = texture
                    self.touch(id)
                    self.evictTextures()
                }
                // A neighbour is known now, so its morph can start, while
                // resting rather than mid-transition.
                if self.transition == nil, let shown = self.shown, shown != id {
                    self.prefetchNeighbours(of: shown)
                }
                self.onNeedsDisplay?()
            }
        }
        return false
    }

    private func ensureMorph(_ key: PairKey, urgent: Bool = true) {
        guard morphs[key] == nil, !morphing.contains(key), let a = infos[key.low], let b = infos[key.high] else { return }
        morphing.insert(key)
        let device = UncheckedSendable(value: device)
        Task.detached(priority: urgent ? .userInitiated : .utility) {
            let (morph, flow) = LiquidPreparation.morph(a, b)
            let textures = UncheckedSendable(value: flow.textures(device: device.value))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.morphing.remove(key)
                if let (ab, ba) = textures.value {
                    self.morphs[key] = PreparedMorph(morph: morph, flow: flow, ab: ab, ba: ba)
                }
                self.onNeedsDisplay?()
            }
        }
    }

    /// Gets the photos either side ready, and their morphs with this one, at
    /// low priority so it never steals frames from what is on screen.
    private func prefetchNeighbours(of id: ObjectIdentifier) {
        guard let index = photos.firstIndex(where: { $0.id == id }), photos.count > 1 else { return }
        let next = photos[(index + 1) % photos.count].id
        let previous = photos[(index - 1 + photos.count) % photos.count].id
        for other in [next, previous] where other != id {
            ensureReady(other, urgent: false)
            ensureMorph(PairKey(id, other), urgent: false)
        }
    }

    private func touch(_ id: ObjectIdentifier) {
        useCounter += 1
        textureUse[id] = useCounter
    }

    /// Keeps the GPU copies of the most recently used few photos only.
    private func evictTextures(keeping limit: Int = 6) {
        guard textures.count > limit else { return }
        let protected = Set([shown, requested, transition?.from, transition?.to].compactMap { $0 })
        let victims = textures.keys
            .filter { !protected.contains($0) }
            .sorted { (textureUse[$0] ?? 0) < (textureUse[$1] ?? 0) }
        for id in victims.prefix(textures.count - limit) {
            textures[id] = nil
        }
    }
}
