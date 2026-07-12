using System;
using NUnit.Framework;
using NUnit.Framework.Interfaces;
using UnityEngine.TestTools;

namespace AreaTargetPlugin.Tests
{
    /// <summary>
    /// Custom NUnit attribute that suppresses Debug.LogError failures in tests.
    /// Apply to a test class or method to ignore all error log messages.
    /// 
    /// NOTE: This attribute alone may not reliably suppress errors in all Unity versions.
    /// For maximum reliability, also add LogAssert.ignoreFailingMessages = true in [SetUp].
    /// </summary>
    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Method)]
    public class IgnoreLogErrorsAttribute : NUnitAttribute, ITestAction
    {
        public ActionTargets Targets => ActionTargets.Test;

        public void BeforeTest(ITest test)
        {
            LogAssert.ignoreFailingMessages = true;
        }

        public void AfterTest(ITest test)
        {
            // Intentionally left empty — do NOT reset ignoreFailingMessages here.
            // Unity's LogScope will handle cleanup when the test ends.
        }
    }
}
