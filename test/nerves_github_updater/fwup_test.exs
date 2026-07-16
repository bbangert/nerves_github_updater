defmodule NervesGithubUpdater.FwupTest do
  use ExUnit.Case, async: true

  alias NervesGithubUpdater.Fwup

  describe "pre-flight error handling (host-safe)" do
    test "returns :missing_devpath when devpath is nil" do
      tmp_fw = write_tmp("dummy")
      assert {:error, :missing_devpath} = Fwup.apply(tmp_fw, fwup_path: "/usr/bin/fwup")
    end

    test "returns {:firmware_not_found, _} when the .fw file does not exist" do
      assert {:error, {:firmware_not_found, "/no/such/file.fw"}} =
               Fwup.apply("/no/such/file.fw", fwup_path: "/usr/bin/fwup", devpath: "/tmp/x")
    end
  end

  describe "port streaming (host-safe, fake fwup executable)" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "fwup_fake_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      devpath = Path.join(tmp_dir, "dest.img")
      File.touch!(devpath)

      %{tmp_dir: tmp_dir, devpath: devpath}
    end

    test "returns :ok when fake fwup drains stdin and exits 0", %{
      tmp_dir: tmp_dir,
      devpath: devpath
    } do
      fwup_path = write_fake_fwup!(tmp_dir, "timeout 5 cat > /dev/null\nexit 0\n")
      fw_path = write_tmp("small firmware payload")

      assert :ok = Fwup.apply(fw_path, devpath: devpath, fwup_path: fwup_path)
    end

    test "returns {:error, {:fwup_exit, 1, _}} when fake fwup drains stdin and exits 1", %{
      tmp_dir: tmp_dir,
      devpath: devpath
    } do
      fwup_path = write_fake_fwup!(tmp_dir, "timeout 5 cat > /dev/null\nexit 1\n")
      fw_path = write_tmp("small firmware payload")

      assert {:error, {:fwup_exit, 1, _}} =
               Fwup.apply(fw_path, devpath: devpath, fwup_path: fwup_path)
    end

    test "mid-stream fwup death (broken pipe) returns an error without crashing the caller", %{
      tmp_dir: tmp_dir,
      devpath: devpath
    } do
      # Fake fwup exits immediately, WITHOUT reading any of stdin. The
      # real Fwup.apply/2 keeps writing a multi-MB .fw to the port after
      # that — outpacing the fake's exit — so the write hits a closed
      # read end (:epipe) partway through streaming. Before the fix,
      # that mid-stream port death delivered an untrapped EXIT signal to
      # the caller (this test process) and crashed it instead of
      # returning an error tuple.
      fwup_path = write_fake_fwup!(tmp_dir, "exit 0\n")
      fw_path = write_big_fw!(tmp_dir, 16 * 1024 * 1024)

      # Linked probe: if the port's mid-stream death ever escapes the
      # isolated worker and reaches this (non-trapping) test process as
      # a raw EXIT signal, the test process dies before the assertions
      # below run, and — being linked — so would this probe.
      probe = spawn_link(fn -> Process.sleep(5_000) end)

      assert {:error, _reason} = Fwup.apply(fw_path, devpath: devpath, fwup_path: fwup_path)

      # Reaching this line at all is the main proof: an untrapped EXIT
      # signal would have killed this process before we got here.
      assert Process.alive?(self())
      assert Process.alive?(probe)

      Process.exit(probe, :kill)
    end
  end

  describe "fwup integration (requires fwup on PATH)" do
    @describetag :hardware

    test "applies a tiny .fw against a loopback file" do
      # Skipped by default. Run with: mise run test -- --include hardware
      fwup = System.find_executable("fwup")
      assert fwup, "fwup not installed; run with --include hardware only on a host with fwup"

      tmp_dir = Path.join(System.tmp_dir!(), "fwup_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      conf_path = Path.join(tmp_dir, "fwup.conf")
      fw_path = Path.join(tmp_dir, "test.fw")
      dest_path = Path.join(tmp_dir, "dest.img")

      File.write!(conf_path, """
      meta-product = "fwup test"
      meta-version = "1.0.0"
      meta-platform = "test"
      meta-architecture = "test"
      meta-author = "test"

      file-resource rootfs.img {
        host-path = "rootfs.img"
      }

      task upgrade {
        on-resource rootfs.img {
          raw_write(0)
        }
      }
      """)

      File.write!(Path.join(tmp_dir, "rootfs.img"), :crypto.strong_rand_bytes(8 * 1024))
      File.touch!(dest_path)

      {_, 0} =
        System.cmd("fwup", ["-c", "-f", conf_path, "-o", fw_path],
          cd: tmp_dir,
          stderr_to_stdout: true
        )

      test_pid = self()
      progress = fn event -> send(test_pid, {:progress, event}) end

      assert :ok = Fwup.apply(fw_path, devpath: dest_path, progress: progress)
      assert_received {:progress, {:flashing, _}}, "expected at least one progress event"
    end
  end

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "fwup_test_#{System.unique_integer([:positive])}.fw")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # Writes a fake fwup executable: a shell script whose behavior after
  # the shebang is `body` (e.g. "timeout 5 cat > /dev/null\nexit 0\n").
  # Used in place of the real fwup binary so the port-streaming path is
  # host-safe to test — the fake never touches `devpath` or parses the
  # framing protocol, it just consumes-or-not stdin and exits.
  #
  # A "drain stdin" fake must bound its read with `timeout`, not a bare
  # `cat`: the Erlang Port keeps our write end of the pipe open until
  # *after* it has already seen this process's exit status, so plain
  # `cat` never observes a real EOF and hangs forever (the same
  # EOF/exit ordering the moduledoc's "no --exit-handshake" note
  # describes for real fwup, which sidesteps it by keying off the
  # zero-length terminator frame instead of pipe EOF).
  defp write_fake_fwup!(tmp_dir, body) do
    path = Path.join(tmp_dir, "fake_fwup_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/usr/bin/env bash\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # A multi-MB .fw big enough that streaming it out-races a fake fwup
  # that exits without draining stdin, forcing a broken-pipe write.
  defp write_big_fw!(tmp_dir, size) do
    path = Path.join(tmp_dir, "big_#{System.unique_integer([:positive])}.fw")
    File.write!(path, :crypto.strong_rand_bytes(size))
    path
  end
end
