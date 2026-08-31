// Adapted from denoland/fastwebsockets autobahn/server-test.js.

const test_directory = decodeURIComponent(
  new URL(".", import.meta.url).pathname,
);
const repository_directory = decodeURIComponent(
  new URL("../..", import.meta.url).pathname,
);
const reports_directory = decodeURIComponent(
  new URL("./reports", import.meta.url).pathname,
);
const report_path = `${reports_directory}/servers/index.json`;
const server_binary = `${repository_directory}/zig-out/bin/autobahn_server`;
const agent_name = "uWebZockets";

const autobahn_testsuite_docker =
  "crossbario/autobahn-testsuite:0.8.2@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074";

await reset_reports();
const reports_owner = await Deno.stat(reports_directory);
const docker_user = container_user(reports_owner);

const server = new Deno.Command(server_binary, {
  cwd: repository_directory,
  stdin: "null",
  stdout: "inherit",
  stderr: "inherit",
}).spawn();
let server_status = null;
const server_done = server.status.then((status) => {
  server_status = status;
  return status;
});

try {
  await wait_for_server();

  const config_mount =
    `${test_directory}/fuzzingclient.json:/fuzzingclient.json:ro`;
  const reports_mount = `${reports_directory}:/reports`;

  const docker = new Deno.Command("docker", {
    args: [
      "run",
      "--name",
      "fuzzingserver",
      "--user",
      docker_user,
      "--volume",
      config_mount,
      "--volume",
      reports_mount,
      "--workdir",
      "/",
      "--net=host",
      "--rm",
      autobahn_testsuite_docker,
      "wstest",
      "-m",
      "fuzzingclient",
      "-s",
      "/fuzzingclient.json",
    ],
    cwd: test_directory,
    stdin: "null",
    stdout: "inherit",
    stderr: "inherit",
  }).spawn();
  const docker_status = await docker.status;
  if (!docker_status.success) {
    throw new Error(
      `Autobahn container failed with ${describe_status(docker_status)}`,
    );
  }

  const report = JSON.parse(await Deno.readTextFile(report_path));
  const agent_report = report[agent_name];
  if (agent_report == null || typeof agent_report !== "object") {
    throw new Error(`Autobahn report does not contain agent ${agent_name}`);
  }

  const results = Object.values(agent_report);
  const failed_tests = results.filter((outcome) =>
    failed(outcome.behavior) || failed(outcome.behaviorClose)
  );

  console.log(JSON.stringify(results, null, 2));
  console.log(
    `%c${results.length - failed_tests.length} / ${results.length} tests OK`,
    `color: ${failed_tests.length === 0 ? "green" : "red"}`,
  );

  if (failed_tests.length !== 0) Deno.exitCode = 1;
} finally {
  await stop_server();
}

function failed(name) {
  return name !== "OK" && name !== "INFORMATIONAL" && name !== "NON-STRICT";
}

async function reset_reports() {
  try {
    await Deno.remove(reports_directory, { recursive: true });
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  await Deno.mkdir(reports_directory, { recursive: true });
}

async function wait_for_server() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (server_status != null) {
      throw new Error(
        `Autobahn server exited before readiness with ${
          describe_status(server_status)
        }`,
      );
    }

    try {
      const connection = await Deno.connect({
        hostname: "127.0.0.1",
        port: 9001,
      });
      connection.close();
      return;
    } catch (error) {
      if (!(error instanceof Deno.errors.ConnectionRefused)) throw error;
    }

    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  throw new Error("Autobahn server did not become ready");
}

async function stop_server() {
  if (server_status != null) return;

  try {
    server.kill("SIGTERM");
  } catch {
    // The child may have exited between the state check and the signal.
  }

  let timeout_id;
  const stopped = await Promise.race([
    server_done.then(() => true),
    new Promise((resolve) => {
      timeout_id = setTimeout(() => resolve(false), 5000);
    }),
  ]);
  clearTimeout(timeout_id);

  if (!stopped) {
    try {
      server.kill("SIGKILL");
    } catch {
      // The child may have exited between the timeout and the signal.
    }
  }

  await server_done;
}

function describe_status(status) {
  if (status.signal != null) return `signal ${status.signal}`;
  return `exit code ${status.code}`;
}

function container_user(file_info) {
  if (file_info.uid == null || file_info.gid == null) {
    throw new Error("Autobahn runner requires POSIX file ownership");
  }
  return `${file_info.uid}:${file_info.gid}`;
}
