using UnityEngine;

namespace VideoPlaybackTestScene
{
    /// <summary>
    /// 播放控制器：管理播放/暂停/逐帧/跳转/速度的状态机。
    /// Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6
    /// </summary>
    public class PlaybackController
    {
        public enum State { Paused, Playing }

        /// <summary>当前播放状态</summary>
        public State CurrentState { get; private set; } = State.Paused;

        /// <summary>当前帧索引</summary>
        public int CurrentFrameIndex { get; private set; }

        /// <summary>是否有新帧需要处理（每次 Tick/Step/Seek 后检查，消费后自动清除）</summary>
        public bool HasNewFrame { get; private set; }

        private int _totalFrames;
        private float _accumulator;
        private float _playbackFPS = 10f;

        /// <summary>播放速率（FPS），clamp 到 [1, 30]</summary>
        public float PlaybackFPS
        {
            get => _playbackFPS;
            set => _playbackFPS = Mathf.Clamp(value, 1f, 30f);
        }

        /// <summary>初始化，设置总帧数，状态重置为 Paused，帧索引为 0</summary>
        public void Setup(int totalFrames)
        {
            _totalFrames = Mathf.Max(0, totalFrames);
            CurrentFrameIndex = 0;
            CurrentState = State.Paused;
            HasNewFrame = false;
            _accumulator = 0f;
        }

        /// <summary>开始播放</summary>
        public void Play()
        {
            if (_totalFrames <= 0) return;
            CurrentState = State.Playing;
        }

        /// <summary>暂停播放</summary>
        public void Pause()
        {
            CurrentState = State.Paused;
        }

        /// <summary>暂停状态下前进一帧，保持 Paused</summary>
        public void StepForward()
        {
            if (CurrentState != State.Paused) return;
            if (_totalFrames <= 0) return;
            if (CurrentFrameIndex < _totalFrames - 1)
            {
                CurrentFrameIndex++;
                HasNewFrame = true;
            }
        }

        /// <summary>跳转到指定帧（自动 clamp 到有效范围）</summary>
        public void SeekTo(int frameIndex)
        {
            if (_totalFrames <= 0) return;
            CurrentFrameIndex = Mathf.Clamp(frameIndex, 0, _totalFrames - 1);
            HasNewFrame = true;
        }

        /// <summary>
        /// 每帧调用，累加时间并在 Playing 状态下按 PlaybackFPS 推进帧。
        /// 到达最后一帧时自动切换到 Paused。
        /// </summary>
        public void Tick(float deltaTime)
        {
            // 消费 HasNewFrame（调用方应在 Tick 前读取）
            HasNewFrame = false;

            if (CurrentState != State.Playing || _totalFrames <= 0) return;

            _accumulator += deltaTime;
            float frameDuration = 1f / _playbackFPS;

            while (_accumulator >= frameDuration)
            {
                _accumulator -= frameDuration;

                if (CurrentFrameIndex < _totalFrames - 1)
                {
                    CurrentFrameIndex++;
                    HasNewFrame = true;
                }
                else
                {
                    // 到达最后一帧，自动暂停
                    CurrentState = State.Paused;
                    _accumulator = 0f;
                    HasNewFrame = true;
                    break;
                }
            }
        }
    }
}
