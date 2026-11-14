using Test, LibGit2
pushfirst!(LOAD_PATH, joinpath(@__DIR__, ".."))
using Kip

me() = LibGit2.Signature("Kip", "kip@example.com", round(Int, time()), 0)

# A repository with one file and one commit
function repository(dir)
  repo = LibGit2.init(dir)
  write(joinpath(dir, "main.jl"), "x = 1\n")
  LibGit2.add!(repo, "main.jl")
  LibGit2.commit(repo, "first"; author=me(), committer=me())
  repo
end

@testset "checkout" begin
  # Snapshots go into a folder of their own, not into ~/.kip/refs
  refs, repos = Kip.refs, Kip.repos
  Core.eval(Kip, :(refs = $(mktempdir())))
  name = ("kip-test", "Checkout.jl", nothing)
  try
    @testset "a package keeps its folder when its repository changes" begin
      dir = mktempdir()
      repo = repository(dir)
      folder = Kip.checkout(repo, name...)
      # A repository with nothing to commit is loaded from a snapshot of its commit
      @test startswith(folder, Kip.refs)
      @test read(joinpath(folder, "main.jl"), String) == "x = 1\n"
      # An edit makes the repository dirty, so a first load now would come from its working tree
      write(joinpath(dir, "main.jl"), "x = 2\n")
      @test Kip.checkout_repo(repo, name...) != folder
      # But this program already has the package, so it stays with the copy it has
      @test Kip.checkout(repo, name...) == folder
    end

    @testset "a package first loaded from its working tree stays there after a commit" begin
      empty!(Kip.checkouts)
      dir = mktempdir()
      repo = repository(dir)
      write(joinpath(dir, "main.jl"), "x = 2\n")
      folder = Kip.checkout(repo, name...)
      @test !startswith(folder, Kip.refs)
      LibGit2.add!(repo, "main.jl")
      LibGit2.commit(repo, "second"; author=me(), committer=me())
      @test startswith(Kip.checkout_repo(repo, name...), Kip.refs)
      @test Kip.checkout(repo, name...) == folder
    end

    # An app that was built ahead of time has the folders from its build. It
    # gives `repos` a new value when it starts, or its `__init__` runs.
    @testset "a package is looked for again when `repos` changes" begin
      empty!(Kip.checkouts)
      dir = mktempdir()
      repo = repository(dir)
      folder = Kip.checkout(repo, name...)
      write(joinpath(dir, "main.jl"), "x = 2\n")
      Core.eval(Kip, :(repos = $(mktempdir())))
      @test Kip.checkout(repo, name...) != folder
    end

    @testset "a program starts with no folders" begin
      @test !isempty(Kip.checkouts)
      home = get(ENV, "KIP_DIR", nothing)
      Kip.__init__()
      @test isempty(Kip.checkouts)
      @test Kip.home == something(home, joinpath(homedir(), ".kip"))
    end
  finally
    empty!(Kip.checkouts)
    Core.eval(Kip, :(refs = $refs; repos = $repos))
  end
end
