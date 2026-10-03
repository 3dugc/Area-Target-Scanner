using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEngine;

namespace AreaTargetPlugin
{
    /// <summary>
    /// Exports bounded, image-free localization diagnostics as JSON Lines.
    /// All record strings are validated before any diagnostics directory or file is
    /// created so capture data and user paths cannot be written accidentally.
    /// </summary>
    public sealed class LocalizationDiagnosticExporter
    {
        private static readonly string[] ForbiddenTokens =
        {
            "ImageData",
            "JPEG",
            "ScanData",
            "/Users/",
            "file://"
        };

        private readonly string _diagnosticsDirectory;

        public LocalizationDiagnosticExporter(string diagnosticsDirectory = null)
        {
            _diagnosticsDirectory = string.IsNullOrWhiteSpace(diagnosticsDirectory)
                ? Path.Combine(Application.persistentDataPath, "AreaTargetDiagnostics")
                : diagnosticsDirectory;
        }

        public string DiagnosticsDirectory => _diagnosticsDirectory;

        /// <summary>
        /// Writes one JSON object per line. Invalid diagnostic strings return an
        /// explicit category and leave the output directory untouched.
        /// </summary>
        public bool TryExport(
            IReadOnlyList<LocalizationDiagnosticRecord> records,
            out string outputPath,
            out LocalizationFailureCategory failureCategory,
            out string failureReason)
        {
            outputPath = null;
            failureCategory = LocalizationFailureCategory.None;
            failureReason = string.Empty;

            if (records == null || records.Count == 0)
                return Fail("No diagnostic records were supplied.", out failureCategory, out failureReason);

            for (int index = 0; index < records.Count; index++)
            {
                if (!TryValidateRecord(records[index], out string validationReason))
                    return Fail(validationReason, out failureCategory, out failureReason);
            }

            LocalizationDiagnosticRecord firstRecord = records[0];
            string mapHashPrefix = GetMapHashPrefix(firstRecord.MapHash);
            if (string.IsNullOrEmpty(mapHashPrefix))
                return Fail("Diagnostic map hash is invalid.", out failureCategory, out failureReason);

            string filename = $"{firstRecord.TimestampUtc:yyyyMMddTHHmmssfffZ}_{mapHashPrefix}.jsonl";
            string candidatePath = Path.Combine(_diagnosticsDirectory, filename);

            try
            {
                Directory.CreateDirectory(_diagnosticsDirectory);
                using (var writer = new StreamWriter(candidatePath, false, new UTF8Encoding(false)))
                {
                    for (int index = 0; index < records.Count; index++)
                        writer.WriteLine(records[index].ToJson());
                }

                outputPath = candidatePath;
                return true;
            }
            catch (Exception exception)
            {
                failureCategory = LocalizationFailureCategory.LifecycleFailure;
                failureReason = $"Diagnostic export failed: {exception.GetType().Name}.";
                return false;
            }
        }

        private static bool Fail(
            string reason,
            out LocalizationFailureCategory failureCategory,
            out string failureReason)
        {
            failureCategory = LocalizationFailureCategory.InvalidFrame;
            failureReason = reason;
            return false;
        }

        private static bool TryValidateRecord(
            LocalizationDiagnosticRecord record,
            out string failureReason)
        {
            failureReason = string.Empty;
            if (record == null)
            {
                failureReason = "Diagnostic record is null.";
                return false;
            }

            string[] values =
            {
                record.BuildVersion,
                record.PackageVersion,
                record.MapId,
                record.MapVersion,
                record.MapHash,
                record.DeviceModel,
                record.OperatingSystem,
                record.FailureReason
            };

            for (int index = 0; index < values.Length; index++)
            {
                string value = values[index] ?? string.Empty;
                if (value.IndexOf('/') >= 0 || value.IndexOf('\\') >= 0)
                {
                    failureReason = "Diagnostic record contains a path separator.";
                    return false;
                }

                for (int forbiddenIndex = 0; forbiddenIndex < ForbiddenTokens.Length; forbiddenIndex++)
                {
                    if (value.IndexOf(ForbiddenTokens[forbiddenIndex], StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        failureReason = "Diagnostic record contains a forbidden capture-data marker.";
                        return false;
                    }
                }
            }

            return true;
        }

        private static string GetMapHashPrefix(string mapHash)
        {
            if (string.IsNullOrWhiteSpace(mapHash))
                return null;

            int prefixLength = Math.Min(12, mapHash.Length);
            for (int index = 0; index < prefixLength; index++)
            {
                char character = mapHash[index];
                if (!char.IsLetterOrDigit(character) && character != '-' && character != '_')
                    return null;
            }

            return mapHash.Substring(0, prefixLength);
        }
    }
}
