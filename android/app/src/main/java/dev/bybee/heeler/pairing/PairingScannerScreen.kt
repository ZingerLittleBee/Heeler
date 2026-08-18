package dev.bybee.heeler.pairing

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.view.ViewGroup
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.bybee.heeler.data.HostStore

/** Full-screen scanner and ceremony surface for the `pairing` route. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairingScannerScreen(
    hostStore: HostStore,
    onHostPaired: (hostId: String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val viewModel: PairingViewModel = viewModel(
        factory = remember(hostStore, context.applicationContext) {
            PairingViewModelFactory(context.applicationContext, hostStore)
        },
    )
    val state by viewModel.state.collectAsState()
    var cameraGranted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        cameraGranted = it
    }

    LaunchedEffect(cameraGranted) {
        if (!cameraGranted) permissionLauncher.launch(Manifest.permission.CAMERA)
    }
    LaunchedEffect(state.pairedHost?.id) {
        state.pairedHost?.id?.let(onHostPaired)
    }

    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text("Pair Host") }) },
    ) { padding ->
        when {
            !context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) -> {
                ScannerNotice(
                    title = "No camera available",
                    body = "This device cannot scan a Pairing Code. Add the Host manually instead.",
                    action = onBack,
                    actionLabel = "Back",
                    modifier = Modifier.padding(padding),
                )
            }
            !cameraGranted -> {
                ScannerNotice(
                    title = "Camera permission required",
                    body = "Camera access lets Heeler read a Pairing Code. The image stays on this device.",
                    action = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                    actionLabel = "Allow camera",
                    modifier = Modifier.padding(padding),
                )
            }
            else -> {
                Box(Modifier.fillMaxSize().padding(padding)) {
                    BarcodeCameraPreview(
                        enabled = !state.scanned && state.pairedHost == null,
                        onValue = viewModel::submitScanned,
                        modifier = Modifier.fillMaxSize(),
                    )
                    PairingOverlay(
                        state = state,
                        onRetry = viewModel::pair,
                        onScanAgain = viewModel::scanAgain,
                        modifier = Modifier.align(Alignment.BottomCenter).padding(20.dp),
                    )
                }
            }
    }
}
}

@Composable
private fun BarcodeCameraPreview(
    enabled: Boolean,
    onValue: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scanner = remember { BarcodeScanning.getClient() }
    var previewView by remember { mutableStateOf<PreviewView?>(null) }

    DisposableEffect(lifecycleOwner, scanner, enabled, previewView) {
        val previewTarget = previewView
        if (!enabled || previewTarget == null) {
            onDispose { }
        } else {
            val providerFuture = ProcessCameraProvider.getInstance(context)
            val executor = ContextCompat.getMainExecutor(context)
            providerFuture.addListener({
                val provider = runCatching { providerFuture.get() }.getOrNull() ?: return@addListener
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewTarget.surfaceProvider)
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { useCase ->
                        useCase.setAnalyzer(executor) { imageProxy ->
                            val mediaImage = imageProxy.image
                            if (mediaImage == null) {
                                imageProxy.close()
                            } else {
                                scanner.process(
                                    InputImage.fromMediaImage(
                                        mediaImage,
                                        imageProxy.imageInfo.rotationDegrees,
                                    ),
                                )
                                    .addOnSuccessListener { barcodes ->
                                        barcodes.firstOrNull { it.format == Barcode.FORMAT_QR_CODE }
                                            ?.rawValue
                                            ?.let(onValue)
                                    }
                                    .addOnCompleteListener { imageProxy.close() }
                            }
                        }
                    }
                runCatching {
                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )
                }
            }, executor)
            onDispose {
                providerFuture.addListener(
                    { runCatching { providerFuture.get().unbindAll() } },
                    executor,
                )
            }
        }
    }
    DisposableEffect(scanner) { onDispose { scanner.close() } }

    AndroidView(
        modifier = modifier.background(Color.Black),
        factory = {
            PreviewView(it).also { view ->
                view.layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                view.scaleType = PreviewView.ScaleType.FILL_CENTER
                previewView = view
            }
        },
    )
}

@Composable
private fun PairingOverlay(
    state: PairingUiState,
    onRetry: () -> Unit,
    onScanAgain: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            when {
                state.isPairing -> {
                    CircularProgressIndicator()
                    Text(state.currentStep?.label ?: "Pairing", style = MaterialTheme.typography.titleMedium)
                    Text("Keep the Pairing Code visible until the ceremony finishes.")
                }
                state.failure != null -> {
                    Text(state.failure.step.label, style = MaterialTheme.typography.titleMedium)
                    Text(state.failure.message)
                    if (state.failure.canRetry) {
                        Button(onClick = onRetry) { Text("Try Again") }
                    }
                    OutlinedButton(onClick = onScanAgain) { Text("Scan Another Code") }
                }
                state.scanError != null -> {
                    Text(state.scanError, color = MaterialTheme.colorScheme.error)
                    OutlinedButton(onClick = onScanAgain) { Text("Scan Again") }
                }
                !state.scanned -> {
                    Text("Scan a Pairing Code", style = MaterialTheme.typography.titleMedium)
                    Text("Pairing connects with a one-time Bootstrap Key, enrolls this device's Device Key, then verifies it.")
                }
            }
        }
    }
}

@Composable
private fun ScannerNotice(
    title: String,
    body: String,
    action: () -> Unit,
    actionLabel: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(12.dp))
        Text(body)
        Spacer(Modifier.height(24.dp))
        Button(onClick = action) { Text(actionLabel) }
    }
}

private class PairingViewModelFactory(
    private val context: Context,
    private val hostStore: HostStore,
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = PairingViewModel(context, hostStore) as T
}
