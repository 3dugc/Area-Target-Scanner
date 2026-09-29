using System;
using System.Collections.Generic;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Thread-safe fixed-size FIFO for image-free diagnostic records.
    /// When full, the oldest record is discarded and counted.
    /// </summary>
    public sealed class BoundedDiagnosticBuffer
    {
        private readonly object _gate = new object();
        private readonly Queue<LocalizationDiagnosticRecord> _records;
        private readonly int _capacity;
        private long _droppedRecordCount;

        public BoundedDiagnosticBuffer(int capacity)
        {
            if (capacity <= 0)
                throw new ArgumentOutOfRangeException(nameof(capacity), "Capacity must be positive.");

            _capacity = capacity;
            _records = new Queue<LocalizationDiagnosticRecord>(capacity);
        }

        public long DroppedRecordCount
        {
            get
            {
                lock (_gate)
                {
                    return _droppedRecordCount;
                }
            }
        }

        public void Add(LocalizationDiagnosticRecord record)
        {
            if (record == null)
                throw new ArgumentNullException(nameof(record));

            lock (_gate)
            {
                if (_records.Count == _capacity)
                {
                    _records.Dequeue();
                    _droppedRecordCount++;
                }

                _records.Enqueue(record);
            }
        }

        public IReadOnlyList<LocalizationDiagnosticRecord> Snapshot()
        {
            lock (_gate)
            {
                return _records.ToArray();
            }
        }
    }
}
