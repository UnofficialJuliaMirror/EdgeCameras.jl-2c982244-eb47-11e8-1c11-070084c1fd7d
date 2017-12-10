module Cornercam

using Images
using VideoIO: openvideo, VideoReader
using StaticArrays: SVector, SMatrix
using CoordinateTransformations
using Interpolations
using Unitful


struct TransformedVideo{F <: Function, R <: VideoReader, M <: AbstractArray}
    transform::F
    video::R
    buffer::M
end

function TransformedVideo(f::Function, v::VideoReader)
    buf = read(v)
    TransformedVideo(f, v, buf)
end

Base.seek(v::TransformedVideo, s) = seek(v.video, s)

function Base.read(v::TransformedVideo)
    read!(v.video, v.buffer)
    v.transform(v.buffer)
end

function Base.read!(v::TransformedVideo, out::AbstractArray)
    read!(v.video, v.buffer)
    out .= v.transform(v.buffer)
end

framerate(v::VideoReader) = v.stream_info.stream.avg_frame_rate.num / (v.stream_info.stream.avg_frame_rate.den * u"s")
framerate(v::TransformedVideo) = framerate(v.video)

const AbstractVideo = Union{VideoReader, TransformedVideo}

struct Homography2D{T, M <: AbstractMatrix{T}} <: Transformation
  H::M
end

Homography2D(H::M) where {T, M <: AbstractMatrix{T}} = Homography2D{T, M}(H)

Base.inv(H::Homography2D) = Homography2D(inv(H.H))

@inline function (trans::Homography2D)(x)
    xprime = trans.H * SVector(x[1], x[2], 1)
    scale = 1 / xprime[end]
    SVector(xprime[1] * scale, xprime[2] * scale)
end

function rectify(original_corners, desired_corners)
    @assert length(original_corners) == length(desired_corners)
    N = length(original_corners)
    A = zeros(8, 8)
    for i in 1:N
        row = 2 * i - 1
        x1, y1 = original_corners[i]
        x2, y2 = desired_corners[i]
        A[row, :] = [x1, y1, 1, 0, 0, 0, -x1*x2, -y1*x2]
        A[row+1, :] = [0, 0, 0, x1, y1, 1, -x1*y2, -y1*y2]
    end
    b = vcat(desired_corners...)
    h = vcat(A \ b, 1)
    H = reshape(h, 3, 3)'
    Homography2D(SMatrix{3, 3}(H))
end

polar_samples(θs, rs) = [CartesianFromPolar()(Polar(x[2], x[1])) for x in Iterators.product(θs, rs)]

struct Params{Tθ, TS}
    θs::Tθ
    samples::TS
    σ::Float64
end

function visibility_gain(samples, θs)
    N = length(θs)
    M = length(samples)
    A = zeros(N0f8, M, N)
    for (j, θ) in enumerate(θs)
        for (i, sample) in enumerate(samples)
            ρ = atan2(sample[2], sample[1])
            A[i, j] = ρ > θ
        end
    end
    A
end

function cornercam_gain(A::AbstractMatrix, σ, λ)
    Ã = hcat(ones(size(A, 1)), A)

    G = I - diagm(ones(size(Ã, 2) - 1), 1)
    G = G[1:end-1, :]
    G[1, :] = 0

    c = eye(size(G, 2))
    c[1, :] = 0

    R = Tridiagonal((G' * G + c)) / σ^2

    Σinv = Ã' * Ã / λ^2 + R
    gain = (Σinv \ (Ã' / λ^2));
end

struct CornerCamera{S <: AbstractVideo, H <: Homography2D, M <: AbstractArray, P <: Params}
    source::S
    homography::H
    background::M
    params::P
end

function show_samples(c::CornerCamera)
    im = desaturate.(c.background)
    color = interpolate([RGB(1., 0, 0), RGB(0., 0, 1)], BSpline(Linear()), OnGrid())
    for (i, s) in enumerate(c.params.samples)
        pixel = c.homography(s)
        mark!(im, pixel, 1, color[1 + i / length(c.params.samples)])
    end
    im
end

function frames_between(video::AbstractVideo, time_range::Tuple)
    rate = framerate(video)
    seek(video, convert(Float64, time_range[1] / (1u"s")))
    num_frames = round(Int, (time_range[2] - time_range[1]) * rate)
    return (read(video) for i in 1:num_frames)
end

function desaturate(px::RGB)
    g = gray(Gray(px))
    RGB(g, g, g)
end

function mark!(im::AbstractArray, center, radius::Integer=3, color=RGB(1., 0, 0))
    for dx in -radius:radius
        for dy in -radius:radius
            p = round.(Int, center .+ SVector(dx, dy))
            im[Tuple(p)...] = color
        end
    end
end

function sample(im, samples, H)
    itp = interpolate(im, BSpline(Linear()), OnGrid())
    [itp[Tuple(H(s))...] for s in samples]
end

function imnormal(im)
    lb = minimum(x -> min(red(x), green(x), blue(x)), im)
    ub = maximum(x -> max(red(x), green(x), blue(x)), im)
    (im .- RGB(lb, lb, lb)) ./ (ub - lb)
end

end