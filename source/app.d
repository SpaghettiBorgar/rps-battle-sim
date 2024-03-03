import std.stdio;
import etc.linux.memoryerror;
import bindbc.sdl;
import std.string;
import std.random;
import std.conv;
import std.math;
import std.datetime.stopwatch;
import std.concurrency;
import std.functional;
import std.traits;
import std.range;

/// Exception for SDL related issues
class SDLException : Exception
{
	/// Creates an exception from SDL_GetError()
	this(string file = __FILE__, size_t line = __LINE__) nothrow @nogc
	{
		super(cast(string) SDL_GetError().fromStringz, file, line);
	}
}

enum RPS
{
	ROCK,
	PAPER,
	SCISSORS
}

real normdist(real s = 1, real m = 0, T)(T x) pure
{
	immutable real fact = 1 / (s * sqrt(2 * PI));
	real p = (x-m)/s;
	return fact * exp((p * p) / -2);
}

ReturnType!fun[] buildLUT(alias fun, R)(R range) {
	ReturnType!fun[] ret = [];
	foreach(i; range) {
		ret ~= fun(i);
	}
	return ret;
}

static immutable normdistLUT = buildLUT!(normdist!(100,0,int))(iota(4096));

struct Point
{
	real x;
	real y;

	real angle(Point p2 = Point(0, 0)) pure const
	{
		// return atan2(p2.x - this.x, (p2.y - this.y));
		return atan2(-(p2.y - this.y), p2.x - this.x);
	}

	real distance(Point p2 = Point(0, 0)) pure const
	{
		auto dx = p2.x - this.x;
		auto dy = p2.y - this.y;
		return sqrt(dx * dx + dy * dy);
	}

	void movePolar(real angle, real distance)
	{
		this.x += cos(angle) * distance;
		this.y -= sin(angle) * distance;
	}

	void rotate(real angle)
	{
		this.x = cos(angle) * this.x - sin(angle) * this.y;
		this.y = sin(angle) * this.x + cos(angle) * this.y;
	}

	auto opBinary(string op)(const Point rhs) const
	{
		mixin(q{return Point(x} ~ op ~ q{rhs.x, y} ~ op ~ q{rhs.y);});
	}

	auto opBinary(string op)(const real rhs) const
	{
		mixin(q{return Point(x} ~ op ~ q{rhs, y} ~ op ~ q{rhs);});
	}

	void opOpAssign(string op, T)(T rhs)
	{
		mixin(q{this = this} ~ op ~ q{rhs;});
	}

	string toString() const
	{
		return this.x.to!string ~ "," ~ this.y.to!string;
	}

	bool isDefined()
	{
		return !(isNaN(x) || isNaN(y));
	}
}

struct Particle
{
	RPS type;
	Point pos;
	Point vel = Point(0, 0);
	Point vel_smooth = Point(0, 0);
}

immutable size_t N_PARTICLES = 250;

SDL_Renderer* sdlr;
__gshared bool running;
__gshared int windowW;
__gshared int windowH;
int mouseX;
int mouseY;
bool mouseL;
bool mouseM;
bool mouseR;
ubyte* keystates;
ushort keymods;
__gshared Particle[N_PARTICLES] particles;
__gshared SDL_Surface* heatmap_surf;
Tid heatmap_thread;

SDL_Texture* rock_tex;
SDL_Texture* paper_tex;
SDL_Texture* scissors_tex;

void main()
{
	version(DMD)
	registerMemoryErrorHandler();

	// writeln(sdlSupport);

	if (loadSDL() != sdlSupport)
		writeln("Error loading SDL library");

	if (loadSDLImage() < sdlImageSupport)
		writeln("Error loading SDL Image library");

	if (SDL_Init(SDL_INIT_VIDEO) < 0)
		throw new SDLException();

	if (IMG_Init(IMG_INIT_PNG) != IMG_INIT_PNG)
		throw new SDLException();

	scope (exit)
		SDL_Quit();

	windowW = 1200;
	windowH = 900;
	auto window = SDL_CreateWindow("SDL Application", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
		windowW, windowH, SDL_WINDOW_SHOWN);
	if (!window)
		throw new SDLException();

	sdlr = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);

	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
	// SDL_SetHint(SDL_HINT_RENDER_LINE_METHOD, "2");
	SDL_SetRenderDrawBlendMode(sdlr, SDL_BLENDMODE_BLEND);

	rock_tex = SDL_CreateTextureFromSurface(sdlr, IMG_Load("./rock.png"));
	paper_tex = SDL_CreateTextureFromSurface(sdlr, IMG_Load("./paper.png"));
	scissors_tex = SDL_CreateTextureFromSurface(sdlr, IMG_Load("./scissors.png"));
	if(rock_tex is null || paper_tex is null || scissors_tex is null) {
		throw new SDLException();
	}

	init();

	heatmap_thread = spawn(&heatmapWorker);

	auto sw = StopWatch(AutoStart.yes);
	running = true;
	while (running)
	{
		sw.reset();
		pollEvents();
		tick();
		long tick_msecs = sw.peek.total!"msecs";
		sw.reset();
		draw();
		long draw_msecs = sw.peek.total!"msecs";
		writefln!"tick %d msecs, draw %d msecs"(tick_msecs, draw_msecs);
	}
}

void init()
{
	auto rnd = MinstdRand0();

	foreach(i; 0..N_PARTICLES)
	{
		particles[i] = Particle(rnd.uniform!RPS, Point(uniform01() * windowW, uniform01() * windowH), Point(0, 0), Point(0, 0));
	}
}

void tick()
{
	import std.algorithm : min, max, clamp;

	real gravity(Point p1, Point p2)
	{
		return 2 / pow(max(4, p1.distance(p2)) / 4, 2);
	}

	foreach(ref p; particles)
	{
		Point f = Point(0, 0);
		// f.movePolar(uniform01() * 2 * PI, uniform01() * 0.4);
		f.x += 8 / pow(p.pos.x / 4, 2) - 8 / pow((windowW - p.pos.x) / 4, 2);
		f.y += 8 / pow(p.pos.y / 4, 2) - 8 / pow((windowH - p.pos.y) / 4, 2);
		Particle* nearest;
		real nearest_dist;
		foreach(ref p2; particles)
		{
			if (p == p2)
				continue;
			real dist = p.pos.distance(p2.pos);
			if(nearest is null || dist < nearest_dist) 
			{
				nearest = &p2;
				nearest_dist = dist;
			}
			// if(dist <= 300)
				f.movePolar(p.pos.angle(p2.pos), gravity(p.pos, p2.pos) * (p.type == p2.type ? -0.9 : 1));
		}
		if(p.pos.distance(nearest.pos) <= 16)
		{
			if ((nearest.type + 3 - p.type) % 3 == 1) {
				p.type = nearest.type;
			}
		}
		// p.pos.movePolar(5, 1);
		// f.movePolar(f.angle(Point(0,0)), 0.1);
		// f.rotate(1);
		p.vel += f * 0.9;
		p.vel *= 0.9;
		// p.vel.rotate(0.1);
		p.pos += p.vel;
		p.pos.x = clamp(p.pos.x, 2, windowW - 2);
		p.pos.y = clamp(p.pos.y, 2, windowH - 2);
		p.vel_smooth = p.vel_smooth * 0.95 + p.vel * 0.5;
	}
}

void draw()
{
	sdlr.SDL_SetRenderDrawColor(0, 0, 0, 255);
	sdlr.SDL_RenderClear();

	int nrock = 0;
	int npaper = 0;
	int nscissors = 0;

	foreach(p; particles)
	{
		SDL_Texture* tex;
		switch(p.type)
		{
			case RPS.ROCK:
				tex = rock_tex;
				sdlr.SDL_SetRenderDrawColor(0, 0, 255, 200);
				nrock++;
				break;
			case RPS.PAPER:
				tex = paper_tex;
				sdlr.SDL_SetRenderDrawColor(0, 255, 0, 200);
				npaper++;
				break;
			case RPS.SCISSORS:
				tex = scissors_tex;
				sdlr.SDL_SetRenderDrawColor(255, 0, 0, 200);
				nscissors++;
				break;
			default:
				assert(0);
		}
		// sdlr.SDL_RenderFillRectF(new SDL_FRect(p.pos.x - 4, p.pos.y - 4, 8, 8));
		sdlr.SDL_RenderCopyExF(tex, null, new SDL_FRect(p.pos.x - 8, p.pos.y - 8, 16, 16), p.vel_smooth.angle(Point(-1, 0)) * 180 / PI, null, 0);
		// sdlr.SDL_RenderCopyF(tex, null, new SDL_FRect(p.pos.x - 8, p.pos.y - 8, 16, 16));
		// sdlr.SDL_BlitSurface(surf, null, new SDL_Rect(p.pos.x.to!int - 4, p.pos.y.to!int - 4, 8, 8));
	}
	sdlr.SDL_RenderCopy(rock_tex, null, new SDL_Rect(4 + 20 * 0, windowH - 20, 16, 16));
	sdlr.SDL_SetRenderDrawColor(0, 0, 255, 255);
	sdlr.SDL_RenderFillRect(new SDL_Rect(4 + 20 * 0, windowH - 22 - nrock, 16, nrock));
	sdlr.SDL_RenderCopy(paper_tex, null, new SDL_Rect(4 + 20 * 1, windowH - 20, 16, 16));
	sdlr.SDL_SetRenderDrawColor(0, 255, 0, 255);
	sdlr.SDL_RenderFillRect(new SDL_Rect(4 + 20 * 1, windowH - 22 - npaper, 16, npaper));
	sdlr.SDL_RenderCopy(scissors_tex, null, new SDL_Rect(4 + 20 * 2, windowH - 20, 16, 16));
	sdlr.SDL_SetRenderDrawColor(255, 0, 0, 255);
	sdlr.SDL_RenderFillRect(new SDL_Rect(4 + 20 * 2, windowH - 22 - nscissors, 16, nscissors));

	static SDL_Texture* heatmap_tex;

	if(heatmap_tex !is null && heatmap_surf !is null) {
		heatmap_tex.SDL_UpdateTexture(null, heatmap_surf.pixels, heatmap_surf.pitch);
		if(sdlr.SDL_RenderCopy(heatmap_tex, null, new SDL_Rect(62, windowH - windowH / 8, windowW / 8, windowH / 8)) < 0) {
			throw new SDLException();
		}
	
		// SDL_DestroyTexture(heatmap_tex);
	} else if (heatmap_surf !is null) {
		heatmap_tex = sdlr.SDL_CreateTextureFromSurface(heatmap_surf);
	}

	sdlr.SDL_RenderPresent();
}

void heatmapWorker()
{
	ubyte[] data = new ubyte[(windowW / 8) * (windowH / 8) * 4];
	auto sw = StopWatch(AutoStart.yes);
	while(running)
	{
		sw.reset();
		for(int x = 0; x < windowW / 8; x++) {
			for(int y = 0; y < windowH / 8; y++) {
				int di = (y * (windowW / 8) + x) * 4;
				(cast(uint*) data)[di / 4] = 0;
				for(int i = 0; i < N_PARTICLES; i++) {
					Particle p = particles[i];
					// s[p.type] += 5 * 255 * normdist!real(p.pos.distance(Point(x * 8, y * 8)), 100);
					data[di + 2 - p.type] += (800 * normdistLUT[(p.pos.distance(Point(x * 8, y * 8))).to!int]).to!int;
					// data[di+0] = 0;
					// data[di+1] = 0;
					// data[di+2] = 255;
					data[di+3] = 255;
				}
			}
		}
		if(heatmap_surf is null)
			heatmap_surf = SDL_CreateRGBSurfaceFrom(cast(void*) data, windowW / 8, windowH / 8, 32, (windowW / 8) * 4, 0xFF << 0, 0xFF << 8, 0xFF << 16, 0xFF << 24);
		if(heatmap_surf is null) {
			writeln(SDL_GetError().fromStringz);
			throw new SDLException();
		}
		writefln!"heatmap %d msecs"(sw.peek.total!"msecs");
	}
}

void pollEvents()
{
	SDL_Event event;
	while (SDL_PollEvent(&event))
	{
		switch (event.type)
		{
		case SDL_QUIT:
			quit();
			break;
		case SDL_KEYDOWN:
			onKeyDown(event.key);
			break;
		case SDL_KEYUP:
			onKeyUp(event.key);
			break;
		case SDL_TEXTINPUT:
			onTextInput(event.text);
			break;
		case SDL_MOUSEBUTTONDOWN:
			onMouseDown(event.button);
			break;
		case SDL_MOUSEBUTTONUP:
			onMouseUp(event.button);
			break;
		case SDL_MOUSEMOTION:
			onMouseMotion(event.motion);
			break;
		case SDL_MOUSEWHEEL:
			onMouseWheel(event.wheel);
			break;
		case SDL_WINDOWEVENT:
			onWindowEvent(event.window);
			break;
		default:
			writeln("Unhandled event: ", cast(SDL_EventType) event.type);
		}
	}
}

void quit()
{
	running = false;
}

void onKeyDown(SDL_KeyboardEvent e)
{
	keystates = SDL_GetKeyboardState(null);
	keymods = e.keysym.mod;
	switch (e.keysym.sym)
	{
	case SDLK_ESCAPE:
		quit();
		break;
	default:
	}
}

void onKeyUp(SDL_KeyboardEvent e)
{
	keystates = SDL_GetKeyboardState(null);
	keymods = e.keysym.mod;
	switch (e.keysym.sym)
	{
	default:
	}
}

void onMouseDown(SDL_MouseButtonEvent e)
{
	mouseX = e.x;
	mouseY = e.y;
	switch (e.button)
	{
	case SDL_BUTTON_LEFT:
		mouseL = true;
		break;
	case SDL_BUTTON_MIDDLE:
		mouseM = true;
		break;
	case SDL_BUTTON_RIGHT:
		mouseR = true;
		break;
	case SDL_BUTTON_X1:
	case SDL_BUTTON_X2:
	default:
	}
}

void onTextInput(SDL_TextInputEvent e)
{

}

void onMouseUp(SDL_MouseButtonEvent e)
{
	mouseX = e.x;
	mouseY = e.y;
	switch (e.button)
	{
	case SDL_BUTTON_LEFT:
		mouseL = false;
		break;
	case SDL_BUTTON_MIDDLE:
		mouseM = false;
		break;
	case SDL_BUTTON_RIGHT:
		mouseR = false;
		break;
	case SDL_BUTTON_X1:
	case SDL_BUTTON_X2:
	default:
	}
}

void onMouseMotion(SDL_MouseMotionEvent e)
{
	mouseX = e.x;
	mouseY = e.y;
}

void onMouseWheel(SDL_MouseWheelEvent e)
{

}

void onWindowEvent(SDL_WindowEvent e)
{
	switch (e.event)
	{
	case SDL_WINDOWEVENT_SHOWN:
	case SDL_WINDOWEVENT_HIDDEN:
		break;
	case SDL_WINDOWEVENT_EXPOSED:
		draw();
		break;
	case SDL_WINDOWEVENT_MOVED:
		break;
	case SDL_WINDOWEVENT_RESIZED:
		windowW = e.data1;
		windowH = e.data2;
		init();
		break;
	case SDL_WINDOWEVENT_MINIMIZED:
	case SDL_WINDOWEVENT_MAXIMIZED:
	case SDL_WINDOWEVENT_ENTER:
	case SDL_WINDOWEVENT_LEAVE:
	case SDL_WINDOWEVENT_FOCUS_GAINED:
	case SDL_WINDOWEVENT_FOCUS_LOST:
	case SDL_WINDOWEVENT_CLOSE:
	default:
	}
}
