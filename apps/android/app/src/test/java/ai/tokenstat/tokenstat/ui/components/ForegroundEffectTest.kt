package ai.tokenstat.tokenstat.ui.components

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ForegroundEffectTest {
    @Test fun `polling stops in background and restarts once on return`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val owner = object : LifecycleOwner {
                override val lifecycle = LifecycleRegistry.createUnsafe(this)
            }
            val lifecycle = owner.lifecycle
            var starts = 0
            var stops = 0
            val job = launch {
                lifecycle.runWhileStarted {
                    starts++
                    try { awaitCancellation() } finally { stops++ }
                }
            }
            lifecycle.currentState = Lifecycle.State.CREATED
            runCurrent()
            assertEquals(0, starts)
            lifecycle.currentState = Lifecycle.State.STARTED
            runCurrent()
            assertEquals(1, starts)
            lifecycle.currentState = Lifecycle.State.RESUMED
            runCurrent()
            assertEquals(1, starts)
            lifecycle.currentState = Lifecycle.State.CREATED
            runCurrent()
            assertEquals(1, stops)
            lifecycle.currentState = Lifecycle.State.STARTED
            runCurrent()
            assertEquals(2, starts)
            lifecycle.currentState = Lifecycle.State.DESTROYED
            runCurrent()
            assertEquals(2, stops)
            assertTrue(job.isCompleted)
        } finally { Dispatchers.resetMain() }
    }
}
