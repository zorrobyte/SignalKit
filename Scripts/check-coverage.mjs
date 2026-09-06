import { readFileSync } from 'node:fs';

const report = JSON.parse(readFileSync(process.argv[2], 'utf8'));
// Native adapters remain INCLUDED. These are regression floors, not a claim
// that simulator coverage establishes real-device correctness.
const floors = { DurableSync: 0.97, ActivityTracking: 0.91, HealthSync: 0.81 };
const fileFloors = { 'DurableWriteLog.swift': 0.97, 'ActivityEngine.swift': 0.95,
  'LocationCoordinator.swift': 0.95, 'MotionCoordinator.swift': 0.98,
  'HealthSyncCoordinator.swift': 0.92, 'HealthUploadPipeline.swift': 0.95 };
let failed = false;
// This non-product target is statically linked into ExampleTests. Count only
// the example implementation files, never the test source itself.
const exampleFiles = ['OfflineTrackingOutput.swift', 'HealthConfiguration.swift'].map(name =>
  report.targets.find(t => t.name === 'ExampleTests')?.files.find(f => f.name === name));
const exampleCoverage = exampleFiles.every(Boolean)
  ? exampleFiles.reduce((n, f) => n + f.coveredLines, 0) / exampleFiles.reduce((n, f) => n + f.executableLines, 0)
  : 0;
console.log(`SignalKitExamples: ${(exampleCoverage * 100).toFixed(2)}% (minimum 95%)`);
if (exampleCoverage < 0.95) failed = true;
for (const [name, floor] of Object.entries(floors)) {
  const target = report.targets.find(t => t.name === name);
  const coverage = target?.lineCoverage ?? 0;
  console.log(`${name}: ${(coverage * 100).toFixed(2)}% (minimum ${floor * 100}%)`);
  if (coverage < floor) failed = true;
}
for (const [name, floor] of Object.entries(fileFloors)) {
  const file = report.targets.flatMap(t => t.files ?? []).find(f => f.name === name);
  if (!file || file.lineCoverage < floor) {
    console.error(`${name}: missing or below ${floor * 100}%`);
    failed = true;
  }
}
if (failed) process.exit(1);
